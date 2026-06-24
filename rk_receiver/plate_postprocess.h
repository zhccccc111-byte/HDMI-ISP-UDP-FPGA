#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "rknn_runtime.h"

namespace plate {

struct Detection {
    float x1;
    float y1;
    float x2;
    float y2;
    float score;
    int cls;
};

using DetectionBatch = std::vector<std::vector<Detection>>;

const std::vector<std::string>& plate_chars();
const std::unordered_map<std::string, std::string>& province_ascii_map();
std::string plate_to_ascii(const std::string& plate);
DetectionBatch postprocess_fastestdet_batches(
    const float* data,
    int n,
    int c,
    int h,
    int w,
    float conf_thresh,
    float nms_thresh,
    int det_num_classes);
std::vector<Detection> postprocess_fastestdet_output_tensor(
    const OutputTensor& output,
    float conf_thresh,
    float nms_thresh,
    int det_num_classes,
    std::string* error_message = nullptr);
std::string decode_plate_utf8(const int64_t* indices, std::size_t len);
std::string decode_plate_utf8(const std::vector<int64_t>& indices);
std::string decode_plate_ascii(const int64_t* indices, std::size_t len);
std::string decode_plate_ascii(const std::vector<int64_t>& indices);

}  // namespace plate
