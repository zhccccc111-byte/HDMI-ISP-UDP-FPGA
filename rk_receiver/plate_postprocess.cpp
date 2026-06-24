#include "plate_postprocess.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

namespace plate {
namespace {

float iou(const Detection& a, const Detection& b) {
    const float xx1 = std::max(a.x1, b.x1);
    const float yy1 = std::max(a.y1, b.y1);
    const float xx2 = std::min(a.x2, b.x2);
    const float yy2 = std::min(a.y2, b.y2);
    const float width = std::max(0.0f, xx2 - xx1);
    const float height = std::max(0.0f, yy2 - yy1);
    const float inter = width * height;
    const float area_a = std::max(0.0f, a.x2 - a.x1) * std::max(0.0f, a.y2 - a.y1);
    const float area_b = std::max(0.0f, b.x2 - b.x1) * std::max(0.0f, b.y2 - b.y1);
    return inter / (area_a + area_b - inter + 1e-6f);
}

std::vector<Detection> nms_by_class(std::vector<Detection> dets, float nms_thresh) {
    std::sort(dets.begin(), dets.end(), [](const Detection& a, const Detection& b) {
        return a.score > b.score;
    });

    std::vector<Detection> kept;
    std::vector<bool> suppressed(dets.size(), false);
    for (std::size_t i = 0; i < dets.size(); ++i) {
        if (suppressed[i]) {
            continue;
        }
        kept.push_back(dets[i]);
        for (std::size_t j = i + 1; j < dets.size(); ++j) {
            if (!suppressed[j] && iou(dets[i], dets[j]) > nms_thresh) {
                suppressed[j] = true;
            }
        }
    }
    return kept;
}

inline float sigmoid(float x) {
    return 1.0f / (1.0f + std::exp(-x));
}

float fp16_to_float(uint16_t value) {
    const uint32_t sign = static_cast<uint32_t>(value & 0x8000U) << 16;
    int exponent = static_cast<int>((value >> 10) & 0x1FU);
    uint32_t mantissa = value & 0x03FFU;

    if (exponent == 0) {
        if (mantissa == 0U) {
            const uint32_t bits = sign;
            float out = 0.0f;
            std::memcpy(&out, &bits, sizeof(out));
            return out;
        }

        while ((mantissa & 0x0400U) == 0U) {
            mantissa <<= 1U;
            --exponent;
        }
        ++exponent;
        mantissa &= 0x03FFU;
    } else if (exponent == 31) {
        const uint32_t bits = sign | 0x7F800000U | (mantissa << 13U);
        float out = 0.0f;
        std::memcpy(&out, &bits, sizeof(out));
        return out;
    }

    exponent = exponent + (127 - 15);
    const uint32_t bits = sign | (static_cast<uint32_t>(exponent) << 23U) | (mantissa << 13U);
    float out = 0.0f;
    std::memcpy(&out, &bits, sizeof(out));
    return out;
}

float dequantize_scalar(int32_t raw_value, const TensorShape& shape) {
    switch (shape.qnt_type) {
    case RKNN_TENSOR_QNT_AFFINE_ASYMMETRIC:
        return (static_cast<float>(raw_value) - static_cast<float>(shape.zp)) * shape.scale;
    case RKNN_TENSOR_QNT_DFP:
        return std::ldexp(static_cast<float>(raw_value), shape.fl);
    case RKNN_TENSOR_QNT_NONE:
    default:
        return static_cast<float>(raw_value);
    }
}

std::size_t tensor_type_size_bytes(rknn_tensor_type type) {
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
    case RKNN_TENSOR_INT8:
    case RKNN_TENSOR_UINT8:
    case RKNN_TENSOR_BOOL:
    default:
        return 1;
    }
}

float tensor_value_as_float(const OutputTensor& output, std::size_t index) {
    if (output.is_float_output) {
        return output.values[index];
    }

    switch (output.shape.type) {
    case RKNN_TENSOR_INT8:
        return dequantize_scalar(static_cast<int32_t>(reinterpret_cast<const int8_t*>(output.raw_bytes.data())[index]), output.shape);
    case RKNN_TENSOR_UINT8:
        return dequantize_scalar(static_cast<int32_t>(reinterpret_cast<const uint8_t*>(output.raw_bytes.data())[index]), output.shape);
    case RKNN_TENSOR_INT16: {
        int16_t value = 0;
        std::memcpy(&value, output.raw_bytes.data() + index * sizeof(value), sizeof(value));
        return dequantize_scalar(static_cast<int32_t>(value), output.shape);
    }
    case RKNN_TENSOR_UINT16: {
        uint16_t value = 0;
        std::memcpy(&value, output.raw_bytes.data() + index * sizeof(value), sizeof(value));
        return dequantize_scalar(static_cast<int32_t>(value), output.shape);
    }
    case RKNN_TENSOR_FLOAT16: {
        uint16_t value = 0;
        std::memcpy(&value, output.raw_bytes.data() + index * sizeof(value), sizeof(value));
        return fp16_to_float(value);
    }
    case RKNN_TENSOR_FLOAT32: {
        float value = 0.0f;
        std::memcpy(&value, output.raw_bytes.data() + index * sizeof(value), sizeof(value));
        return value;
    }
    default:
        return 0.0f;
    }
}

bool tensor_to_detector_shape(
    const OutputTensor& output,
    int* n,
    int* c,
    int* h,
    int* w,
    bool* is_nhwc,
    std::string* error_message) {
    if (n == nullptr || c == nullptr || h == nullptr || w == nullptr || is_nhwc == nullptr) {
        if (error_message != nullptr) {
            *error_message = "检测输出转换参数为空";
        }
        return false;
    }

    const auto& dims = output.shape.dims;
    if (dims.size() == 4) {
        *is_nhwc = output.shape.fmt == RKNN_TENSOR_NHWC;
        if (*is_nhwc) {
            *n = dims[0];
            *h = dims[1];
            *w = dims[2];
            *c = dims[3];
        } else {
            *n = dims[0];
            *c = dims[1];
            *h = dims[2];
            *w = dims[3];
        }
        return true;
    }

    if (dims.size() == 3) {
        *n = 1;
        *is_nhwc = output.shape.fmt == RKNN_TENSOR_NHWC;
        if (*is_nhwc) {
            *h = dims[0];
            *w = dims[1];
            *c = dims[2];
        } else {
            *c = dims[0];
            *h = dims[1];
            *w = dims[2];
        }
        return true;
    }

    if (error_message != nullptr) {
        *error_message = "检测输出维度不符合预期";
    }
    return false;
}

std::vector<std::string> build_chars() {
    return {
        "#", "京", "沪", "津", "渝", "冀", "晋", "蒙", "辽", "吉", "黑", "苏", "浙", "皖", "闽", "赣", "鲁", "豫", "鄂", "湘", "粤", "桂", "琼", "川", "贵", "云", "藏", "陕", "甘", "青", "宁", "新", "学", "警", "港", "澳", "挂", "使", "领", "民", "航", "危",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        "A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "L", "M", "N", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
        "险", "品"
    };
}

}  // namespace

const std::vector<std::string>& plate_chars() {
    static const std::vector<std::string> chars = build_chars();
    return chars;
}

const std::unordered_map<std::string, std::string>& province_ascii_map() {
    static const std::unordered_map<std::string, std::string> mapping = {
        {"京", "JING"}, {"沪", "HU"}, {"津", "JIN"}, {"渝", "YU"}, {"冀", "JI"}, {"晋", "JINX"}, {"蒙", "MENG"}, {"辽", "LIAO"},
        {"吉", "JI2"}, {"黑", "HEI"}, {"苏", "SU"}, {"浙", "ZHE"}, {"皖", "WAN"}, {"闽", "MIN"}, {"赣", "GAN"}, {"鲁", "LU"},
        {"豫", "YU2"}, {"鄂", "E"}, {"湘", "XIANG"}, {"粤", "YUE"}, {"桂", "GUI"}, {"琼", "QIONG"}, {"川", "CHUAN"},
        {"贵", "GUI2"}, {"云", "YUN"}, {"藏", "ZANG"}, {"陕", "SHAN"}, {"甘", "GAN2"}, {"青", "QING"}, {"宁", "NING"},
        {"新", "XIN"}, {"学", "XUE"}, {"警", "JINGW"}, {"港", "GANG"}, {"澳", "AO"}, {"挂", "GUA"}, {"使", "SHI"},
        {"领", "LING"}, {"民", "MIN"}, {"航", "HANG"}, {"危", "WEI"}, {"险", "XIAN"}, {"品", "PIN"}
    };
    return mapping;
}

std::string plate_to_ascii(const std::string& plate) {
    if (plate.empty()) {
        return plate;
    }

    std::string ascii_plate;
    ascii_plate.reserve(plate.size());

    for (std::size_t pos = 0; pos < plate.size();) {
        std::size_t char_len = 0;
        const unsigned char c0 = static_cast<unsigned char>(plate[pos]);
        if ((c0 & 0x80) == 0) {
            char_len = 1;
        } else if ((c0 & 0xE0) == 0xC0) {
            char_len = 2;
        } else if ((c0 & 0xF0) == 0xE0) {
            char_len = 3;
        } else if ((c0 & 0xF8) == 0xF0) {
            char_len = 4;
        } else {
            return plate;
        }

        if (pos + char_len > plate.size()) {
            return plate;
        }

        const std::string ch = plate.substr(pos, char_len);
        const auto it = province_ascii_map().find(ch);
        if (it != province_ascii_map().end()) {
            const bool need_space = !ascii_plate.empty() && ascii_plate.back() != ' ';
            if (need_space) {
                ascii_plate.push_back(' ');
            }
            ascii_plate += it->second;
            if (pos + char_len < plate.size()) {
                ascii_plate.push_back(' ');
            }
        } else {
            ascii_plate += ch;
        }
        pos += char_len;
    }

    return ascii_plate;
}

DetectionBatch postprocess_fastestdet_batches(
    const float* data,
    int n,
    int c,
    int h,
    int w,
    float conf_thresh,
    float nms_thresh,
    int det_num_classes) {
    DetectionBatch outputs;
    outputs.reserve(static_cast<std::size_t>(std::max(n, 0)));
    if (data == nullptr || n <= 0 || c != 5 + det_num_classes || h <= 0 || w <= 0) {
        return outputs;
    }

    for (int batch = 0; batch < n; ++batch) {
        std::vector<std::vector<Detection>> per_class(static_cast<std::size_t>(det_num_classes));
        for (int gy = 0; gy < h; ++gy) {
            for (int gx = 0; gx < w; ++gx) {
                const auto idx = [&](int ch) -> std::size_t {
                    return static_cast<std::size_t>(((batch * c + ch) * h + gy) * w + gx);
                };

                const float pobj = data[idx(0)];
                int best_cls = 0;
                float cls_max = data[idx(5)];
                for (int cls = 1; cls < det_num_classes; ++cls) {
                    const float value = data[idx(5 + cls)];
                    if (value > cls_max) {
                        cls_max = value;
                        best_cls = cls;
                    }
                }

                const float score = std::pow(pobj, 0.6f) * std::pow(cls_max, 0.4f);
                if (score <= conf_thresh) {
                    continue;
                }

                const float dx = data[idx(1)];
                const float dy = data[idx(2)];
                const float dw = data[idx(3)];
                const float dh = data[idx(4)];

                Detection det;
                const float bw = sigmoid(dw);
                const float bh = sigmoid(dh);
                const float bcx = (std::tanh(dx) + static_cast<float>(gx)) / static_cast<float>(w);
                const float bcy = (std::tanh(dy) + static_cast<float>(gy)) / static_cast<float>(h);
                det.x1 = std::max(0.0f, std::min(1.0f, bcx - 0.5f * bw));
                det.y1 = std::max(0.0f, std::min(1.0f, bcy - 0.5f * bh));
                det.x2 = std::max(0.0f, std::min(1.0f, bcx + 0.5f * bw));
                det.y2 = std::max(0.0f, std::min(1.0f, bcy + 0.5f * bh));
                det.score = score;
                det.cls = best_cls;
                per_class[static_cast<std::size_t>(best_cls)].push_back(det);
            }
        }

        std::vector<Detection> merged;
        for (int cls = 0; cls < det_num_classes; ++cls) {
            auto kept = nms_by_class(per_class[static_cast<std::size_t>(cls)], nms_thresh);
            merged.insert(merged.end(), kept.begin(), kept.end());
        }
        outputs.push_back(std::move(merged));
    }
    return outputs;
}

std::vector<Detection> postprocess_fastestdet_output_tensor(
    const OutputTensor& output,
    float conf_thresh,
    float nms_thresh,
    int det_num_classes,
    std::string* error_message) {
    int n = 0;
    int c = 0;
    int h = 0;
    int w = 0;
    bool is_nhwc = false;
    if (!tensor_to_detector_shape(output, &n, &c, &h, &w, &is_nhwc, error_message)) {
        return {};
    }
    if (n <= 0 || c != 5 + det_num_classes || h <= 0 || w <= 0) {
        if (error_message != nullptr) {
            *error_message = "检测输出 shape 不符合 FastestDet 预期";
        }
        return {};
    }

    const std::size_t required_elements =
        static_cast<std::size_t>(n) * static_cast<std::size_t>(c) * static_cast<std::size_t>(h) * static_cast<std::size_t>(w);
    if (output.is_float_output) {
        if (output.values.size() < required_elements) {
            if (error_message != nullptr) {
                *error_message = "检测输出 float 元素数量不足";
            }
            return {};
        }
    } else if (output.raw_bytes.size() < required_elements * tensor_type_size_bytes(output.shape.type)) {
        if (error_message != nullptr) {
            *error_message = "检测输出 raw 字节数不足";
        }
        return {};
    }

    const auto idx = [&](int batch, int ch, int gy, int gx) -> std::size_t {
        if (is_nhwc) {
            return static_cast<std::size_t>(((batch * h + gy) * w + gx) * c + ch);
        }
        return static_cast<std::size_t>(((batch * c + ch) * h + gy) * w + gx);
    };

    std::vector<std::vector<Detection>> per_class(static_cast<std::size_t>(det_num_classes));
    for (int gy = 0; gy < h; ++gy) {
        for (int gx = 0; gx < w; ++gx) {
            const float pobj = tensor_value_as_float(output, idx(0, 0, gy, gx));
            int best_cls = 0;
            float cls_max = tensor_value_as_float(output, idx(0, 5, gy, gx));
            for (int cls = 1; cls < det_num_classes; ++cls) {
                const float value = tensor_value_as_float(output, idx(0, 5 + cls, gy, gx));
                if (value > cls_max) {
                    cls_max = value;
                    best_cls = cls;
                }
            }

            const float score = std::pow(pobj, 0.6f) * std::pow(cls_max, 0.4f);
            if (score <= conf_thresh) {
                continue;
            }

            const float dx = tensor_value_as_float(output, idx(0, 1, gy, gx));
            const float dy = tensor_value_as_float(output, idx(0, 2, gy, gx));
            const float dw = tensor_value_as_float(output, idx(0, 3, gy, gx));
            const float dh = tensor_value_as_float(output, idx(0, 4, gy, gx));

            Detection det;
            const float bw = sigmoid(dw);
            const float bh = sigmoid(dh);
            const float bcx = (std::tanh(dx) + static_cast<float>(gx)) / static_cast<float>(w);
            const float bcy = (std::tanh(dy) + static_cast<float>(gy)) / static_cast<float>(h);
            det.x1 = std::max(0.0f, std::min(1.0f, bcx - 0.5f * bw));
            det.y1 = std::max(0.0f, std::min(1.0f, bcy - 0.5f * bh));
            det.x2 = std::max(0.0f, std::min(1.0f, bcx + 0.5f * bw));
            det.y2 = std::max(0.0f, std::min(1.0f, bcy + 0.5f * bh));
            det.score = score;
            det.cls = best_cls;
            per_class[static_cast<std::size_t>(best_cls)].push_back(det);
        }
    }

    std::vector<Detection> merged;
    for (int cls = 0; cls < det_num_classes; ++cls) {
        auto kept = nms_by_class(per_class[static_cast<std::size_t>(cls)], nms_thresh);
        merged.insert(merged.end(), kept.begin(), kept.end());
    }
    return merged;
}

std::string decode_plate_utf8(const int64_t* indices, std::size_t len) {
    if (indices == nullptr || len == 0) {
        return std::string();
    }

    const auto& chars = plate_chars();
    std::string plate;
    int64_t prev = 0;
    for (std::size_t i = 0; i < len; ++i) {
        const int64_t cur = indices[i];
        if (cur != 0 && cur != prev && cur >= 0 && cur < static_cast<int64_t>(chars.size())) {
            plate += chars[static_cast<std::size_t>(cur)];
        }
        prev = cur;
    }
    return plate;
}

std::string decode_plate_utf8(const std::vector<int64_t>& indices) {
    return decode_plate_utf8(indices.data(), indices.size());
}

std::string decode_plate_ascii(const int64_t* indices, std::size_t len) {
    return plate_to_ascii(decode_plate_utf8(indices, len));
}

std::string decode_plate_ascii(const std::vector<int64_t>& indices) {
    return decode_plate_ascii(indices.data(), indices.size());
}

}  // namespace plate
