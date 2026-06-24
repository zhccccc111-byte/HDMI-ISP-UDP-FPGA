#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "rknn_api.h"

namespace plate {

struct TensorShape {
    std::string name;
    std::vector<int> dims;
    rknn_tensor_type type = RKNN_TENSOR_FLOAT32;
    rknn_tensor_format fmt = RKNN_TENSOR_NCHW;
    uint32_t n_elems = 0;
    uint32_t size_bytes = 0;
    uint32_t size_with_stride = 0;
    uint32_t w_stride = 0;
    uint32_t h_stride = 0;
    int qnt_type = 0;
    int zp = 0;
    int fl = 0;
    float scale = 0.0f;
    uint8_t pass_through = 0;
};

struct OutputTensor {
    std::vector<float> values;
    std::vector<uint8_t> raw_bytes;
    TensorShape shape;
    bool is_float_output = true;
};

struct InferOptions {
    bool prefer_pass_through = false;
    bool want_float_output = true;
    bool prefer_prealloc_output = false;
};

struct InferProfile {
    int64_t inputs_set_us = 0;
    int64_t run_us = 0;
    int64_t outputs_get_us = 0;
    int64_t outputs_release_us = 0;
    int64_t total_us = 0;
    int64_t npu_run_duration_us = -1;
    bool used_pass_through = false;
    bool used_prealloc_output = false;
    bool used_float_output = true;
};

class RknnRuntime {
public:
    RknnRuntime() = default;
    ~RknnRuntime();

    RknnRuntime(const RknnRuntime&) = delete;
    RknnRuntime& operator=(const RknnRuntime&) = delete;
    RknnRuntime(RknnRuntime&& other) noexcept;
    RknnRuntime& operator=(RknnRuntime&& other) noexcept;

    bool load_model(const std::string& model_path, std::string* error_message = nullptr);
    bool infer_u8_nhwc(
        const void* input_data,
        std::size_t input_bytes,
        std::vector<OutputTensor>* outputs,
        std::string* error_message = nullptr);
    bool infer_u8_nhwc_ex(
        const void* input_data,
        std::size_t input_bytes,
        const InferOptions& options,
        std::vector<OutputTensor>* outputs,
        InferProfile* profile = nullptr,
        std::string* error_message = nullptr);
    void release();
    bool query_perf_run(int64_t* run_duration_us, std::string* error_message = nullptr) const;

    const TensorShape& input_attr() const { return input_attr_; }
    const std::vector<TensorShape>& output_attrs() const { return output_attrs_; }
    const TensorShape& native_input_attr() const { return native_input_attr_; }
    const std::vector<TensorShape>& native_output_attrs() const { return native_output_attrs_; }
    const std::string& sdk_api_version() const { return sdk_api_version_; }
    const std::string& sdk_driver_version() const { return sdk_driver_version_; }
    bool loaded() const { return ctx_ != 0; }

private:
    bool query_io_attrs(std::string* error_message);
    void query_sdk_version();
    bool validate_u8_nhwc_input(const TensorShape& attr, std::size_t input_bytes, std::string* error_message) const;
    bool can_use_u8_nhwc_pass_through(std::size_t input_bytes) const;
    static std::size_t tensor_type_size(rknn_tensor_type type);
    static TensorShape to_tensor_shape(const rknn_tensor_attr& attr);

    rknn_context ctx_ = 0;
    TensorShape input_attr_;
    std::vector<TensorShape> output_attrs_;
    TensorShape native_input_attr_;
    std::vector<TensorShape> native_output_attrs_;
    uint32_t input_count_ = 0;
    uint32_t output_count_ = 0;
    std::string sdk_api_version_;
    std::string sdk_driver_version_;
};

}  // namespace plate
