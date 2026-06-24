#include "rknn_runtime.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

namespace plate {
namespace {

using SteadyClock = std::chrono::steady_clock;

int64_t elapsed_us(SteadyClock::time_point begin, SteadyClock::time_point end) {
    return std::chrono::duration_cast<std::chrono::microseconds>(end - begin).count();
}

const char* tensor_type_name(rknn_tensor_type type) {
    switch (type) {
    case RKNN_TENSOR_INT8:
        return "INT8";
    case RKNN_TENSOR_UINT8:
        return "UINT8";
    case RKNN_TENSOR_FLOAT16:
        return "FLOAT16";
    case RKNN_TENSOR_FLOAT32:
        return "FLOAT32";
    case RKNN_TENSOR_INT16:
        return "INT16";
    case RKNN_TENSOR_UINT16:
        return "UINT16";
    case RKNN_TENSOR_INT32:
        return "INT32";
    case RKNN_TENSOR_INT64:
        return "INT64";
    case RKNN_TENSOR_BOOL:
        return "BOOL";
    default:
        return "UNKNOWN";
    }
}

const char* tensor_format_name(rknn_tensor_format fmt) {
    switch (fmt) {
    case RKNN_TENSOR_NCHW:
        return "NCHW";
    case RKNN_TENSOR_NHWC:
        return "NHWC";
    case RKNN_TENSOR_NC1HWC2:
        return "NC1HWC2";
    case RKNN_TENSOR_UNDEFINED:
        return "UNDEFINED";
    default:
        return "UNKNOWN";
    }
}

}  // namespace

RknnRuntime::~RknnRuntime() {
    release();
}

RknnRuntime::RknnRuntime(RknnRuntime&& other) noexcept {
    *this = std::move(other);
}

RknnRuntime& RknnRuntime::operator=(RknnRuntime&& other) noexcept {
    if (this == &other) {
        return *this;
    }
    release();
    ctx_ = other.ctx_;
    input_attr_ = std::move(other.input_attr_);
    output_attrs_ = std::move(other.output_attrs_);
    native_input_attr_ = std::move(other.native_input_attr_);
    native_output_attrs_ = std::move(other.native_output_attrs_);
    input_count_ = other.input_count_;
    output_count_ = other.output_count_;
    sdk_api_version_ = std::move(other.sdk_api_version_);
    sdk_driver_version_ = std::move(other.sdk_driver_version_);
    other.ctx_ = 0;
    other.input_count_ = 0;
    other.output_count_ = 0;
    return *this;
}

bool RknnRuntime::load_model(const std::string& model_path, std::string* error_message) {
    release();

    std::ifstream file(model_path, std::ios::binary | std::ios::ate);
    if (!file) {
        if (error_message != nullptr) {
            *error_message = "无法打开模型文件: " + model_path;
        }
        return false;
    }

    const std::streamsize file_size = file.tellg();
    if (file_size <= 0) {
        if (error_message != nullptr) {
            *error_message = "模型文件为空: " + model_path;
        }
        return false;
    }
    file.seekg(0, std::ios::beg);

    std::vector<unsigned char> model_data(static_cast<std::size_t>(file_size));
    if (!file.read(reinterpret_cast<char*>(model_data.data()), file_size)) {
        if (error_message != nullptr) {
            *error_message = "读取模型文件失败: " + model_path;
        }
        return false;
    }

    const int ret = rknn_init(&ctx_, model_data.data(), static_cast<uint32_t>(model_data.size()), 0, nullptr);
    if (ret != RKNN_SUCC) {
        ctx_ = 0;
        if (error_message != nullptr) {
            *error_message = "rknn_init 失败, ret=" + std::to_string(ret) + ", model=" + model_path;
        }
        return false;
    }

    if (!query_io_attrs(error_message)) {
        release();
        return false;
    }
    query_sdk_version();
    return true;
}

bool RknnRuntime::infer_u8_nhwc(
    const void* input_data,
    std::size_t input_bytes,
    std::vector<OutputTensor>* outputs,
    std::string* error_message) {
    InferOptions options;
    return infer_u8_nhwc_ex(input_data, input_bytes, options, outputs, nullptr, error_message);
}

bool RknnRuntime::infer_u8_nhwc_ex(
    const void* input_data,
    std::size_t input_bytes,
    const InferOptions& options,
    std::vector<OutputTensor>* outputs,
    InferProfile* profile,
    std::string* error_message) {
    InferProfile local_profile;
    const auto total_begin = SteadyClock::now();

    if (ctx_ == 0) {
        if (error_message != nullptr) {
            *error_message = "模型尚未初始化";
        }
        return false;
    }
    if (input_data == nullptr || outputs == nullptr) {
        if (error_message != nullptr) {
            *error_message = "推理输入或输出参数为空";
        }
        return false;
    }
    if (input_count_ != 1) {
        if (error_message != nullptr) {
            *error_message = "当前实现只支持单输入模型, 实际 input_count=" + std::to_string(input_count_);
        }
        return false;
    }

    const bool use_pass_through = options.prefer_pass_through && can_use_u8_nhwc_pass_through(input_bytes);
    local_profile.used_pass_through = use_pass_through;
    local_profile.used_prealloc_output = options.prefer_prealloc_output;
    local_profile.used_float_output = options.want_float_output;

    const TensorShape& active_input_attr = use_pass_through ? native_input_attr_ : input_attr_;
    if (!validate_u8_nhwc_input(active_input_attr, input_bytes, error_message)) {
        return false;
    }

    rknn_input input;
    std::memset(&input, 0, sizeof(input));
    input.index = 0;
    input.type = use_pass_through ? active_input_attr.type : RKNN_TENSOR_UINT8;
    input.size = static_cast<uint32_t>(input_bytes);
    input.fmt = RKNN_TENSOR_NHWC;
    input.pass_through = use_pass_through ? 1 : 0;
    input.buf = const_cast<void*>(input_data);

    const auto inputs_begin = SteadyClock::now();
    int ret = rknn_inputs_set(ctx_, 1, &input);
    const auto inputs_end = SteadyClock::now();
    local_profile.inputs_set_us = elapsed_us(inputs_begin, inputs_end);
    if (ret != RKNN_SUCC) {
        if (error_message != nullptr) {
            *error_message = "rknn_inputs_set 失败, ret=" + std::to_string(ret);
        }
        return false;
    }

    const auto run_begin = SteadyClock::now();
    ret = rknn_run(ctx_, nullptr);
    const auto run_end = SteadyClock::now();
    local_profile.run_us = elapsed_us(run_begin, run_end);
    if (ret != RKNN_SUCC) {
        if (error_message != nullptr) {
            *error_message = "rknn_run 失败, ret=" + std::to_string(ret);
        }
        return false;
    }

    std::string perf_error;
    if (!query_perf_run(&local_profile.npu_run_duration_us, &perf_error)) {
        local_profile.npu_run_duration_us = -1;
    }

    std::vector<rknn_output> raw_outputs(output_count_);
    outputs->resize(output_count_);
    for (uint32_t i = 0; i < output_count_; ++i) {
        auto& raw = raw_outputs[i];
        auto& tensor = (*outputs)[i];
        std::memset(&raw, 0, sizeof(raw));
        raw.index = i;
        raw.want_float = options.want_float_output ? 1 : 0;
        raw.is_prealloc = options.prefer_prealloc_output ? 1 : 0;

        tensor.shape = output_attrs_[i];
        tensor.is_float_output = options.want_float_output;
        if (options.want_float_output) {
            tensor.raw_bytes.clear();
            if (options.prefer_prealloc_output) {
                tensor.values.resize(tensor.shape.n_elems);
                raw.buf = tensor.values.empty() ? nullptr : tensor.values.data();
                raw.size = static_cast<uint32_t>(tensor.values.size() * sizeof(float));
            } else {
                tensor.values.clear();
            }
        } else {
            tensor.values.clear();
            if (options.prefer_prealloc_output) {
                tensor.raw_bytes.resize(tensor.shape.size_bytes);
                raw.buf = tensor.raw_bytes.empty() ? nullptr : tensor.raw_bytes.data();
                raw.size = static_cast<uint32_t>(tensor.raw_bytes.size());
            } else {
                tensor.raw_bytes.clear();
            }
        }
    }

    const auto outputs_begin = SteadyClock::now();
    ret = rknn_outputs_get(ctx_, output_count_, raw_outputs.data(), nullptr);
    const auto outputs_end = SteadyClock::now();
    local_profile.outputs_get_us = elapsed_us(outputs_begin, outputs_end);
    if (ret != RKNN_SUCC) {
        if (error_message != nullptr) {
            *error_message = "rknn_outputs_get 失败, ret=" + std::to_string(ret);
        }
        return false;
    }

    bool success = true;
    for (uint32_t i = 0; i < output_count_; ++i) {
        auto& tensor = (*outputs)[i];
        const auto& raw = raw_outputs[i];
        if (tensor.is_float_output) {
            if (!options.prefer_prealloc_output) {
                tensor.values.resize(tensor.shape.n_elems);
                if (raw.buf != nullptr && tensor.shape.n_elems > 0) {
                    const float* src = static_cast<const float*>(raw.buf);
                    std::copy(src, src + tensor.shape.n_elems, tensor.values.begin());
                }
            }
        } else if (!options.prefer_prealloc_output) {
            tensor.raw_bytes.resize(raw.size);
            if (raw.buf != nullptr && raw.size > 0) {
                std::memcpy(tensor.raw_bytes.data(), raw.buf, raw.size);
            }
        }
    }

    const auto release_begin = SteadyClock::now();
    const int release_ret = rknn_outputs_release(ctx_, output_count_, raw_outputs.data());
    const auto release_end = SteadyClock::now();
    local_profile.outputs_release_us = elapsed_us(release_begin, release_end);
    if (release_ret != RKNN_SUCC) {
        success = false;
        if (error_message != nullptr) {
            *error_message = "rknn_outputs_release 失败, ret=" + std::to_string(release_ret);
        }
    }

    local_profile.total_us = elapsed_us(total_begin, SteadyClock::now());
    if (profile != nullptr) {
        *profile = local_profile;
    }
    return success;
}

bool RknnRuntime::query_perf_run(int64_t* run_duration_us, std::string* error_message) const {
    if (run_duration_us == nullptr) {
        if (error_message != nullptr) {
            *error_message = "perf 输出参数为空";
        }
        return false;
    }

    rknn_perf_run perf_run;
    std::memset(&perf_run, 0, sizeof(perf_run));
    const int ret = rknn_query(ctx_, RKNN_QUERY_PERF_RUN, &perf_run, sizeof(perf_run));
    if (ret != RKNN_SUCC) {
        if (error_message != nullptr) {
            *error_message = "rknn_query(RKNN_QUERY_PERF_RUN) 失败, ret=" + std::to_string(ret);
        }
        return false;
    }
    *run_duration_us = perf_run.run_duration;
    return true;
}

void RknnRuntime::release() {
    if (ctx_ != 0) {
        rknn_destroy(ctx_);
        ctx_ = 0;
    }
    input_attr_ = TensorShape();
    output_attrs_.clear();
    native_input_attr_ = TensorShape();
    native_output_attrs_.clear();
    input_count_ = 0;
    output_count_ = 0;
    sdk_api_version_.clear();
    sdk_driver_version_.clear();
}

bool RknnRuntime::query_io_attrs(std::string* error_message) {
    rknn_input_output_num io_num;
    std::memset(&io_num, 0, sizeof(io_num));
    int ret = rknn_query(ctx_, RKNN_QUERY_IN_OUT_NUM, &io_num, sizeof(io_num));
    if (ret != RKNN_SUCC) {
        if (error_message != nullptr) {
            *error_message = "rknn_query(RKNN_QUERY_IN_OUT_NUM) 失败, ret=" + std::to_string(ret);
        }
        return false;
    }

    input_count_ = io_num.n_input;
    output_count_ = io_num.n_output;
    if (input_count_ == 0 || output_count_ == 0) {
        if (error_message != nullptr) {
            *error_message = "模型输入或输出数量异常";
        }
        return false;
    }

    rknn_tensor_attr input_attr;
    std::memset(&input_attr, 0, sizeof(input_attr));
    input_attr.index = 0;
    ret = rknn_query(ctx_, RKNN_QUERY_INPUT_ATTR, &input_attr, sizeof(input_attr));
    if (ret != RKNN_SUCC) {
        if (error_message != nullptr) {
            *error_message = "rknn_query(RKNN_QUERY_INPUT_ATTR) 失败, ret=" + std::to_string(ret);
        }
        return false;
    }
    input_attr_ = to_tensor_shape(input_attr);

    rknn_tensor_attr native_input_attr;
    std::memset(&native_input_attr, 0, sizeof(native_input_attr));
    native_input_attr.index = 0;
    ret = rknn_query(ctx_, RKNN_QUERY_NATIVE_INPUT_ATTR, &native_input_attr, sizeof(native_input_attr));
    native_input_attr_ = (ret == RKNN_SUCC) ? to_tensor_shape(native_input_attr) : input_attr_;

    output_attrs_.clear();
    output_attrs_.reserve(output_count_);
    native_output_attrs_.clear();
    native_output_attrs_.reserve(output_count_);
    for (uint32_t i = 0; i < output_count_; ++i) {
        rknn_tensor_attr output_attr;
        std::memset(&output_attr, 0, sizeof(output_attr));
        output_attr.index = i;
        ret = rknn_query(ctx_, RKNN_QUERY_OUTPUT_ATTR, &output_attr, sizeof(output_attr));
        if (ret != RKNN_SUCC) {
            if (error_message != nullptr) {
                *error_message = "rknn_query(RKNN_QUERY_OUTPUT_ATTR) 失败, index=" + std::to_string(i) + ", ret=" + std::to_string(ret);
            }
            output_attrs_.clear();
            native_output_attrs_.clear();
            return false;
        }
        output_attrs_.push_back(to_tensor_shape(output_attr));

        rknn_tensor_attr native_output_attr;
        std::memset(&native_output_attr, 0, sizeof(native_output_attr));
        native_output_attr.index = i;
        ret = rknn_query(ctx_, RKNN_QUERY_NATIVE_OUTPUT_ATTR, &native_output_attr, sizeof(native_output_attr));
        native_output_attrs_.push_back((ret == RKNN_SUCC) ? to_tensor_shape(native_output_attr) : output_attrs_.back());
    }
    return true;
}

void RknnRuntime::query_sdk_version() {
    sdk_api_version_.clear();
    sdk_driver_version_.clear();

    rknn_sdk_version version;
    std::memset(&version, 0, sizeof(version));
    const int ret = rknn_query(ctx_, RKNN_QUERY_SDK_VERSION, &version, sizeof(version));
    if (ret != RKNN_SUCC) {
        return;
    }
    sdk_api_version_ = version.api_version;
    sdk_driver_version_ = version.drv_version;
}

bool RknnRuntime::validate_u8_nhwc_input(const TensorShape& attr, std::size_t input_bytes, std::string* error_message) const {
    switch (attr.type) {
    case RKNN_TENSOR_INT8:
    case RKNN_TENSOR_UINT8:
    case RKNN_TENSOR_FLOAT16:
    case RKNN_TENSOR_FLOAT32:
        break;
    default:
        if (error_message != nullptr) {
            *error_message = "当前接口只支持图像类输入张量, 暂不支持该模型输入类型: " + attr.name +
                             ", type=" + tensor_type_name(attr.type);
        }
        return false;
    }
    if (attr.fmt != RKNN_TENSOR_NHWC && attr.fmt != RKNN_TENSOR_NCHW && attr.fmt != RKNN_TENSOR_UNDEFINED) {
        if (error_message != nullptr) {
            *error_message = "当前接口只支持 NHWC/NCHW 图像输入布局, 模型输入格式不匹配: " + attr.name +
                             ", fmt=" + tensor_format_name(attr.fmt);
        }
        return false;
    }
    if (attr.n_elems != 0 && input_bytes != attr.n_elems) {
        if (error_message != nullptr) {
            *error_message = "当前接口按 uint8 NHWC 图像喂入, 输入字节数与模型元素数不匹配, got=" +
                             std::to_string(input_bytes) + ", expect=" + std::to_string(attr.n_elems) +
                             ", model_type=" + tensor_type_name(attr.type) + ", model_fmt=" +
                             tensor_format_name(attr.fmt);
        }
        return false;
    }
    return true;
}

bool RknnRuntime::can_use_u8_nhwc_pass_through(std::size_t input_bytes) const {
    if (native_input_attr_.type != RKNN_TENSOR_UINT8 || native_input_attr_.fmt != RKNN_TENSOR_NHWC) {
        return false;
    }
    if (native_input_attr_.dims.size() != 4) {
        return false;
    }

    const int height = native_input_attr_.dims[1];
    const int width = native_input_attr_.dims[2];
    const int channel = native_input_attr_.dims[3];
    if (height <= 0 || width <= 0 || channel <= 0) {
        return false;
    }

    const std::size_t expected_bytes = static_cast<std::size_t>(height) * static_cast<std::size_t>(width) *
                                       static_cast<std::size_t>(channel) * tensor_type_size(native_input_attr_.type);
    if (expected_bytes != input_bytes) {
        return false;
    }

    if (native_input_attr_.w_stride != 0U && native_input_attr_.w_stride != static_cast<uint32_t>(width)) {
        return false;
    }
    if (native_input_attr_.size_bytes != 0U && native_input_attr_.size_bytes != input_bytes) {
        return false;
    }
    if (native_input_attr_.size_with_stride != 0U && native_input_attr_.size_with_stride != input_bytes) {
        return false;
    }
    return true;
}

std::size_t RknnRuntime::tensor_type_size(rknn_tensor_type type) {
    switch (type) {
    case RKNN_TENSOR_FLOAT32:
    case RKNN_TENSOR_INT32:
        return 4;
    case RKNN_TENSOR_FLOAT16:
    case RKNN_TENSOR_INT16:
    case RKNN_TENSOR_UINT16:
        return 2;
    case RKNN_TENSOR_INT64:
        return 8;
    case RKNN_TENSOR_BOOL:
    case RKNN_TENSOR_INT8:
    case RKNN_TENSOR_UINT8:
    default:
        return 1;
    }
}

TensorShape RknnRuntime::to_tensor_shape(const rknn_tensor_attr& attr) {
    TensorShape shape;
    shape.name = attr.name;
    shape.type = attr.type;
    shape.fmt = attr.fmt;
    shape.n_elems = attr.n_elems;
    shape.size_bytes = attr.size;
    shape.size_with_stride = attr.size_with_stride;
    shape.w_stride = attr.w_stride;
    shape.h_stride = attr.h_stride;
    shape.qnt_type = attr.qnt_type;
    shape.zp = attr.zp;
    shape.fl = attr.fl;
    shape.scale = attr.scale;
    shape.pass_through = attr.pass_through;
    shape.dims.reserve(attr.n_dims);
    for (uint32_t i = 0; i < attr.n_dims; ++i) {
        shape.dims.push_back(static_cast<int>(attr.dims[i]));
    }
    return shape;
}

}  // namespace plate
