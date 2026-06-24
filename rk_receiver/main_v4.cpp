#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>
#include <sstream>

#include <arpa/inet.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/socket.h>
#include <unistd.h>

#include <opencv2/opencv.hpp>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#include <X11/keysym.h>

#ifdef Status
#undef Status
#endif

#ifdef True
#undef True
#endif

#ifdef False
#undef False
#endif

#include "plate_bitmap_font.h"
#include "plate_postprocess.h"
#include "rknn_runtime.h"

namespace {

using SteadyClock = std::chrono::steady_clock;
constexpr Bool kX11False = 0;

enum class ParseResult {
    kOk,
    kHelp,
    kError,
};

constexpr const char* kDetRknnPath = "FastestDet.rknn";
constexpr const char* kRecRknnPath = "best.rknn";
constexpr const char* kDefaultBindIp = "0.0.0.0";
constexpr const char* kDefaultWindowTitle = "RKNN Plate UDP Debug";
constexpr int kDefaultPort = 8080;
constexpr int kDefaultRcvbufMb = 32;
constexpr double kDefaultReportIntervalSec = 1.0;
constexpr int kSrcWidth = 640;
constexpr int kSrcHeight = 640;
constexpr int kHeaderBytes = 6;
constexpr int kSrcPixelBytes = 2;
constexpr int kSrcLineBytes = kSrcWidth * kSrcPixelBytes;
constexpr int kSrcFrameBytes = kSrcLineBytes * kSrcHeight;
constexpr int kExpectedPayload = kHeaderBytes + kSrcLineBytes;
constexpr int kMaxUdpPayload = 2048;
constexpr int kDetInputWidth = 352;
constexpr int kDetInputHeight = 352;
constexpr int kRecInputWidth = 168;
constexpr int kRecInputHeight = 48;
constexpr float kConfThres = 0.5f;
constexpr float kNmsThres = 0.4f;
constexpr int kDetNumClasses = 2;
constexpr std::size_t kDetOutputPoolCapacity = 3;
constexpr std::size_t kDetInputBytes = static_cast<std::size_t>(kDetInputWidth) * kDetInputHeight * 3U;
constexpr int kPlateBoxLineWidth = 2;
constexpr int kPlateTextBaselineGap = 8;
constexpr int kPlateTextGrowPx = 1;
constexpr int kPlateTextCharAdvancePx = 10;
constexpr int kPlateTextCharSpacingPx = 2;
constexpr int kPlateTextBgPadX = 2;
constexpr int kPlateTextBgPadTop = 2;
constexpr int kPlateTextBgPadBottom = 2;
constexpr int kPlateTextAsciiBaselineOffset = 18;
constexpr int kPlateTextFallbackInsetX = 7;
constexpr int kPlateTextInsideFallbackGap = 4;

int64_t elapsed_us(SteadyClock::time_point begin, SteadyClock::time_point end) {
    return std::chrono::duration_cast<std::chrono::microseconds>(end - begin).count();
}

double us_to_ms(int64_t us) {
    return static_cast<double>(us) / 1000.0;
}

double metric_us_to_ms(int64_t us) {
    return us < 0 ? -1.0 : us_to_ms(us);
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

const char* qnt_type_name(int qnt_type) {
    switch (qnt_type) {
    case RKNN_TENSOR_QNT_NONE:
        return "NONE";
    case RKNN_TENSOR_QNT_DFP:
        return "DFP";
    case RKNN_TENSOR_QNT_AFFINE_ASYMMETRIC:
        return "AFFINE_ASYMMETRIC";
    default:
        return "UNKNOWN";
    }
}

std::string dims_to_string(const std::vector<int>& dims) {
    std::ostringstream oss;
    oss << "[";
    for (std::size_t i = 0; i < dims.size(); ++i) {
        if (i != 0) {
            oss << ",";
        }
        oss << dims[i];
    }
    oss << "]";
    return oss.str();
}

std::string describe_tensor_shape(const plate::TensorShape& shape) {
    std::ostringstream oss;
    oss << "name=" << shape.name
        << " dims=" << dims_to_string(shape.dims)
        << " fmt=" << tensor_format_name(shape.fmt)
        << " type=" << tensor_type_name(shape.type)
        << " qnt=" << qnt_type_name(shape.qnt_type)
        << " zp=" << shape.zp
        << " scale=" << shape.scale
        << " fl=" << shape.fl
        << " elems=" << shape.n_elems
        << " size=" << shape.size_bytes
        << " size_stride=" << shape.size_with_stride
        << " w_stride=" << shape.w_stride
        << " h_stride=" << shape.h_stride
        << " pass_through=" << static_cast<int>(shape.pass_through);
    return oss.str();
}

bool can_use_detector_pass_through(const plate::RknnRuntime& detector) {
    const auto& attr = detector.native_input_attr();
    if (attr.type != RKNN_TENSOR_UINT8 || attr.fmt != RKNN_TENSOR_NHWC) {
        return false;
    }
    if (attr.dims.size() != 4) {
        return false;
    }
    if (attr.dims[1] != kDetInputHeight || attr.dims[2] != kDetInputWidth || attr.dims[3] != 3) {
        return false;
    }
    if (attr.w_stride != 0U && attr.w_stride != static_cast<uint32_t>(kDetInputWidth)) {
        return false;
    }
    if (attr.size_bytes != 0U && attr.size_bytes != kDetInputBytes) {
        return false;
    }
    if (attr.size_with_stride != 0U && attr.size_with_stride != kDetInputBytes) {
        return false;
    }
    return true;
}

int64_t time_point_ms(SteadyClock::time_point tp) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(tp.time_since_epoch()).count();
}

uint32_t read_be32(const uint8_t* p) {
    return (static_cast<uint32_t>(p[0]) << 24) |
           (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8) |
           static_cast<uint32_t>(p[3]);
}

uint16_t read_be16(const uint8_t* p) {
    return static_cast<uint16_t>((static_cast<uint16_t>(p[0]) << 8) | static_cast<uint16_t>(p[1]));
}

uint8_t expand_5bit(uint16_t value) {
    return static_cast<uint8_t>((value << 3) | (value >> 2));
}

uint8_t expand_6bit(uint16_t value) {
    return static_cast<uint8_t>((value << 2) | (value >> 4));
}

void decode_rgb565_be(const uint8_t* src, uint8_t* r, uint8_t* g, uint8_t* b) {
    const uint16_t rgb565 = static_cast<uint16_t>((static_cast<uint16_t>(src[0]) << 8) | static_cast<uint16_t>(src[1]));
    *r = expand_5bit(static_cast<uint16_t>((rgb565 >> 11) & 0x1F));
    *g = expand_6bit(static_cast<uint16_t>((rgb565 >> 5) & 0x3F));
    *b = expand_5bit(static_cast<uint16_t>(rgb565 & 0x1F));
}

struct UdpOptions {
    std::string bind_ip = kDefaultBindIp;
    int port = kDefaultPort;
    bool has_source_ip = false;
    in_addr source_ip{};
    uint16_t source_port = 0;
    int rcvbuf_mb = kDefaultRcvbufMb;
    int scale = 1;
    double report_interval_sec = kDefaultReportIntervalSec;
    std::string title = kDefaultWindowTitle;
};

void print_usage(const char* prog) {
    std::cout
        << "Usage: " << prog << " [options]\n\n"
        << "Options:\n"
        << "  -b, --bind-ip IP         Bind IP, default: " << kDefaultBindIp << "\n"
        << "  -p, --port PORT          Bind UDP port, default: " << kDefaultPort << "\n"
        << "  -s, --source-ip IP       Only accept packets from this source IP\n"
        << "  -r, --source-port PORT   Only accept packets from this source port\n"
        << "  -B, --rcvbuf-mb N        Socket receive buffer in MB, default: " << kDefaultRcvbufMb << "\n"
        << "  -S, --scale N            Integer X11 scale, default: 1\n"
        << "  -i, --interval SEC       Debug report interval, default: " << kDefaultReportIntervalSec << "\n"
        << "  -t, --title TEXT         X11 window title\n"
        << "  -h, --help               Show this help\n";
}

ParseResult parse_options(int argc, char** argv, UdpOptions* opt, std::string* error_message) {
    auto require_value = [&](int index, const std::string& arg) -> const char* {
        if (index + 1 >= argc) {
            if (error_message != nullptr) {
                *error_message = "缺少参数值: " + arg;
            }
            return nullptr;
        }
        return argv[index + 1];
    };

    try {
        for (int i = 1; i < argc; ++i) {
            const std::string arg = argv[i];
            if (arg == "-h" || arg == "--help") {
                print_usage(argv[0]);
                return ParseResult::kHelp;
            }
            if (arg == "-b" || arg == "--bind-ip") {
                const char* value = require_value(i, arg);
                if (value == nullptr) {
                    return ParseResult::kError;
                }
                opt->bind_ip = value;
                ++i;
                continue;
            }
            if (arg == "-p" || arg == "--port") {
                const char* value = require_value(i, arg);
                if (value == nullptr) {
                    return ParseResult::kError;
                }
                opt->port = std::stoi(value);
                ++i;
                continue;
            }
            if (arg == "-s" || arg == "--source-ip") {
                const char* value = require_value(i, arg);
                if (value == nullptr) {
                    return ParseResult::kError;
                }
                if (inet_aton(value, &opt->source_ip) == 0) {
                    if (error_message != nullptr) {
                        *error_message = "非法 source-ip: " + std::string(value);
                    }
                    return ParseResult::kError;
                }
                opt->has_source_ip = true;
                ++i;
                continue;
            }
            if (arg == "-r" || arg == "--source-port") {
                const char* value = require_value(i, arg);
                if (value == nullptr) {
                    return ParseResult::kError;
                }
                const int port = std::stoi(value);
                if (port < 0 || port > 65535) {
                    if (error_message != nullptr) {
                        *error_message = "非法 source-port: " + std::to_string(port);
                    }
                    return ParseResult::kError;
                }
                opt->source_port = static_cast<uint16_t>(port);
                ++i;
                continue;
            }
            if (arg == "-B" || arg == "--rcvbuf-mb") {
                const char* value = require_value(i, arg);
                if (value == nullptr) {
                    return ParseResult::kError;
                }
                opt->rcvbuf_mb = std::stoi(value);
                ++i;
                continue;
            }
            if (arg == "-S" || arg == "--scale") {
                const char* value = require_value(i, arg);
                if (value == nullptr) {
                    return ParseResult::kError;
                }
                opt->scale = std::stoi(value);
                ++i;
                continue;
            }
            if (arg == "-i" || arg == "--interval") {
                const char* value = require_value(i, arg);
                if (value == nullptr) {
                    return ParseResult::kError;
                }
                opt->report_interval_sec = std::stod(value);
                ++i;
                continue;
            }
            if (arg == "-t" || arg == "--title") {
                const char* value = require_value(i, arg);
                if (value == nullptr) {
                    return ParseResult::kError;
                }
                opt->title = value;
                ++i;
                continue;
            }

            if (error_message != nullptr) {
                *error_message = "未知参数: " + arg;
            }
            return ParseResult::kError;
        }
    } catch (const std::exception& exc) {
        if (error_message != nullptr) {
            *error_message = std::string("参数解析失败: ") + exc.what();
        }
        return ParseResult::kError;
    }

    if (opt->port <= 0 || opt->port > 65535) {
        if (error_message != nullptr) {
            *error_message = "port 必须在 1-65535 范围内";
        }
        return ParseResult::kError;
    }
    if (opt->rcvbuf_mb <= 0) {
        if (error_message != nullptr) {
            *error_message = "rcvbuf-mb 必须大于 0";
        }
        return ParseResult::kError;
    }
    if (opt->scale <= 0) {
        if (error_message != nullptr) {
            *error_message = "scale 必须大于 0";
        }
        return ParseResult::kError;
    }
    if (opt->report_interval_sec <= 0.0) {
        if (error_message != nullptr) {
            *error_message = "interval 必须大于 0";
        }
        return ParseResult::kError;
    }
    return ParseResult::kOk;
}

int create_socket(const UdpOptions& opt) {
    const int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }

    {
        int on = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on)) < 0) {
            perror("setsockopt(SO_REUSEADDR)");
        }
    }

    {
        const int rcvbuf = opt.rcvbuf_mb * 1024 * 1024;
        if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf)) < 0) {
            perror("setsockopt(SO_RCVBUF)");
        }
    }

    {
        const int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            perror("fcntl(O_NONBLOCK)");
        }
    }

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(opt.port));
    if (inet_aton(opt.bind_ip.c_str(), &addr.sin_addr) == 0) {
        std::cerr << "Invalid bind IP: " << opt.bind_ip << std::endl;
        close(fd);
        return -1;
    }

    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        perror("bind");
        close(fd);
        return -1;
    }

    return fd;
}

struct RawFrameTask {
    int frame_id = 0;
    uint32_t udp_frame_id = 0;
    std::shared_ptr<std::vector<uint8_t>> frame_rgb565;
    cv::Mat det_input;
    int64_t source_timestamp_ms = 0;
    bool concealed = false;
    int received_lines = 0;
    int64_t concealed_lines = 0;
    int64_t read_us = 0;
    int64_t recv_assemble_us = 0;
    int64_t det_preprocess_us = 0;
};

struct DetOutputBundle {
    std::vector<plate::OutputTensor> outputs;
    plate::InferProfile profile;
};

struct FrameTask {
    int frame_id = 0;
    uint32_t udp_frame_id = 0;
    std::shared_ptr<std::vector<uint8_t>> frame_rgb565;
    std::shared_ptr<DetOutputBundle> det_bundle;
    int64_t source_timestamp_ms = 0;
    bool concealed = false;
    int received_lines = 0;
    int64_t concealed_lines = 0;
    int64_t read_us = 0;
    int64_t recv_assemble_us = 0;
    int64_t det_preprocess_us = 0;
    int64_t det_inputs_set_us = 0;
    int64_t det_run_api_us = 0;
    int64_t det_outputs_get_us = 0;
    int64_t det_outputs_release_us = 0;
    int64_t det_npu_run_us = -1;
    int det_pass_through_enabled = 0;
    int64_t det_infer_us = 0;
    int64_t det_post_us = 0;
    int64_t det_total_us = 0;
};

struct OverlayItem {
    int x1 = 0;
    int y1 = 0;
    int x2 = 0;
    int y2 = 0;
    std::string text;
};

struct DisplayTask {
    int frame_id = 0;
    uint32_t udp_frame_id = 0;
    std::shared_ptr<std::vector<uint8_t>> frame_rgb565;
    std::vector<OverlayItem> overlays;
    int64_t source_timestamp_ms = 0;
    bool concealed = false;
    int received_lines = 0;
    int64_t concealed_lines = 0;
    int det_box_count = 0;
    int recognized_plate_count = 0;
    double fps = 0.0;
    int64_t read_us = 0;
    int64_t recv_assemble_us = 0;
    int64_t det_preprocess_us = 0;
    int64_t det_inputs_set_us = 0;
    int64_t det_run_api_us = 0;
    int64_t det_outputs_get_us = 0;
    int64_t det_outputs_release_us = 0;
    int64_t det_npu_run_us = -1;
    int det_pass_through_enabled = 0;
    int64_t det_infer_us = 0;
    int64_t det_post_us = 0;
    int64_t det_total_us = 0;
    int64_t rec_preprocess_us = 0;
    int64_t rec_infer_us = 0;
    int64_t rec_decode_us = 0;
    int64_t rec_draw_us = 0;
    int64_t rec_total_us = 0;
};

struct ErrorState {
    mutable std::mutex mutex;
    std::string message;

    void set_once(const std::string& text) {
        std::lock_guard<std::mutex> lock(mutex);
        if (message.empty()) {
            message = text;
        }
    }

    std::string get() const {
        std::lock_guard<std::mutex> lock(mutex);
        return message;
    }
};

struct QueueStats {
    std::atomic<int64_t> push_count{0};
    std::atomic<int64_t> pop_count{0};
    std::atomic<int64_t> overwrite_count{0};
    std::atomic<int64_t> timeout_count{0};
    std::atomic<int> last_pushed_frame_id{-1};
    std::atomic<int> last_popped_frame_id{-1};
};

struct UdpCounters {
    std::atomic<int64_t> packets_total{0};
    std::atomic<int64_t> packets_filtered_in{0};
    std::atomic<int64_t> packets_payload_ok{0};
    std::atomic<int64_t> packets_bad_size{0};
    std::atomic<int64_t> packets_bad_line{0};
    std::atomic<int64_t> duplicates{0};
    std::atomic<int64_t> old_frame_packets{0};
    std::atomic<int64_t> complete_frames{0};
    std::atomic<int64_t> concealed_frames{0};
    std::atomic<int64_t> concealed_lines{0};
    std::atomic<int> current_frame_id{-1};
    std::atomic<int> current_lines_received{0};
};

struct PipelineStats {
    std::atomic<int64_t> read_count{0};
    std::atomic<int64_t> detect_count{0};
    std::atomic<int64_t> recognize_count{0};
    std::atomic<int64_t> display_count{0};

    std::atomic<int> last_read_frame_id{-1};
    std::atomic<int> last_detect_frame_id{-1};
    std::atomic<int> last_recognize_frame_id{-1};
    std::atomic<int> last_display_frame_id{-1};

    std::atomic<int> last_udp_frame_id{-1};
    std::atomic<int> last_detect_jump{1};
    std::atomic<int> last_recognize_jump{1};
    std::atomic<int> last_display_jump{1};
    std::atomic<int> max_detect_jump{1};
    std::atomic<int> max_recognize_jump{1};
    std::atomic<int> max_display_jump{1};

    std::atomic<int> last_received_lines{0};
    std::atomic<int64_t> last_concealed_lines{0};
    std::atomic<int> last_concealed_flag{0};

    std::atomic<int64_t> last_source_timestamp_ms{0};
    std::atomic<int64_t> last_read_us{0};
    std::atomic<int64_t> last_recv_assemble_us{0};
    std::atomic<int64_t> last_det_preprocess_us{0};
    std::atomic<int64_t> last_det_inputs_set_us{0};
    std::atomic<int64_t> last_det_run_api_us{0};
    std::atomic<int64_t> last_det_outputs_get_us{0};
    std::atomic<int64_t> last_det_outputs_release_us{0};
    std::atomic<int64_t> last_det_npu_run_us{-1};
    std::atomic<int> last_det_pass_through{0};
    std::atomic<int64_t> last_det_infer_us{0};
    std::atomic<int64_t> last_det_post_us{0};
    std::atomic<int64_t> last_det_total_us{0};
    std::atomic<int64_t> last_rec_preprocess_us{0};
    std::atomic<int64_t> last_rec_infer_us{0};
    std::atomic<int64_t> last_rec_decode_us{0};
    std::atomic<int64_t> last_rec_draw_us{0};
    std::atomic<int64_t> last_rec_total_us{0};
    std::atomic<int64_t> last_display_draw_us{0};
    std::atomic<int64_t> last_display_present_us{0};
    std::atomic<int64_t> last_display_overlay_us{0};
    std::atomic<int64_t> last_display_event_us{0};
    std::atomic<int64_t> last_display_total_us{0};
    std::atomic<int> last_det_box_count{0};
    std::atomic<int> last_recognized_plate_count{0};
};

int debug_frame_id(const std::shared_ptr<RawFrameTask>& item) {
    return item ? item->frame_id : -1;
}

int debug_frame_id(const std::shared_ptr<FrameTask>& item) {
    return item ? item->frame_id : -1;
}

int debug_frame_id(const std::shared_ptr<DisplayTask>& item) {
    return item ? item->frame_id : -1;
}

template <typename T>
int debug_frame_id(const T&) {
    return -1;
}

class DetOutputPool {
public:
    explicit DetOutputPool(std::size_t capacity) {
        free_.reserve(capacity);
        for (std::size_t i = 0; i < capacity; ++i) {
            free_.push_back(std::make_unique<DetOutputBundle>());
        }
    }

    std::shared_ptr<DetOutputBundle> acquire() {
        std::unique_ptr<DetOutputBundle> bundle;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cond_.wait(lock, [&]() { return !free_.empty(); });
            bundle = std::move(free_.back());
            free_.pop_back();
        }

        bundle->profile = plate::InferProfile{};
        bundle->outputs.clear();
        return std::shared_ptr<DetOutputBundle>(bundle.release(), [this](DetOutputBundle* ptr) { release(ptr); });
    }

private:
    void release(DetOutputBundle* ptr) {
        ptr->profile = plate::InferProfile{};
        ptr->outputs.clear();
        {
            std::lock_guard<std::mutex> lock(mutex_);
            free_.emplace_back(ptr);
        }
        cond_.notify_one();
    }

    std::mutex mutex_;
    std::condition_variable cond_;
    std::vector<std::unique_ptr<DetOutputBundle>> free_;
};

template <typename T>
class LatestQueue {
public:
    explicit LatestQueue(QueueStats* stats = nullptr) : stats_(stats) {}

    void push_latest(T item) {
        const int frame_id = debug_frame_id(item);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (has_item_ && stats_ != nullptr) {
                stats_->overwrite_count.fetch_add(1, std::memory_order_relaxed);
            }
            item_ = std::move(item);
            has_item_ = true;
        }
        if (stats_ != nullptr) {
            stats_->push_count.fetch_add(1, std::memory_order_relaxed);
            stats_->last_pushed_frame_id.store(frame_id, std::memory_order_relaxed);
        }
        cond_.notify_one();
    }

    bool wait_pop_for(T* out, std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (!cond_.wait_for(lock, timeout, [&]() { return has_item_; })) {
            if (stats_ != nullptr) {
                stats_->timeout_count.fetch_add(1, std::memory_order_relaxed);
            }
            return false;
        }
        *out = std::move(*item_);
        item_.reset();
        has_item_ = false;
        if (stats_ != nullptr) {
            stats_->pop_count.fetch_add(1, std::memory_order_relaxed);
            stats_->last_popped_frame_id.store(debug_frame_id(*out), std::memory_order_relaxed);
        }
        return true;
    }

private:
    std::mutex mutex_;
    std::condition_variable cond_;
    std::optional<T> item_;
    bool has_item_ = false;
    QueueStats* stats_ = nullptr;
};

void update_jump_stat(std::atomic<int>* last_frame_id, std::atomic<int>* last_jump, std::atomic<int>* max_jump, int frame_id) {
    const int previous_id = last_frame_id->exchange(frame_id, std::memory_order_relaxed);
    const int jump = (previous_id >= 0 && frame_id >= previous_id) ? (frame_id - previous_id) : 1;
    last_jump->store(jump, std::memory_order_relaxed);

    int current_max = max_jump->load(std::memory_order_relaxed);
    while (jump > current_max && !max_jump->compare_exchange_weak(current_max, jump, std::memory_order_relaxed)) {
    }
}

struct ResizePlan {
    std::vector<int> src_x_for_dst;
    std::vector<int> src_y_for_dst;
    std::vector<std::vector<int>> dst_rows_for_src;
};

ResizePlan build_resize_plan(int src_width, int src_height, int dst_width, int dst_height) {
    ResizePlan plan;
    plan.src_x_for_dst.resize(dst_width);
    plan.src_y_for_dst.resize(dst_height);
    plan.dst_rows_for_src.resize(src_height);

    for (int dx = 0; dx < dst_width; ++dx) {
        const double src = (static_cast<double>(dx) + 0.5) * static_cast<double>(src_width) / static_cast<double>(dst_width) - 0.5;
        const int nearest = std::clamp(static_cast<int>(std::lround(src)), 0, src_width - 1);
        plan.src_x_for_dst[dx] = nearest;
    }
    for (int dy = 0; dy < dst_height; ++dy) {
        const double src = (static_cast<double>(dy) + 0.5) * static_cast<double>(src_height) / static_cast<double>(dst_height) - 0.5;
        const int nearest = std::clamp(static_cast<int>(std::lround(src)), 0, src_height - 1);
        plan.src_y_for_dst[dy] = nearest;
        plan.dst_rows_for_src[nearest].push_back(dy);
    }
    return plan;
}

void process_rgb565_line_to_det_input(const uint8_t* src_line, int src_y, const ResizePlan& plan, cv::Mat* det_input) {
    if (src_y < 0 || src_y >= static_cast<int>(plan.dst_rows_for_src.size())) {
        return;
    }
    const auto& dst_rows = plan.dst_rows_for_src[static_cast<std::size_t>(src_y)];
    if (dst_rows.empty()) {
        return;
    }

    std::vector<uint8_t> row_rgb(static_cast<std::size_t>(kDetInputWidth) * 3U);
    for (int dx = 0; dx < kDetInputWidth; ++dx) {
        const int sx = plan.src_x_for_dst[static_cast<std::size_t>(dx)];
        uint8_t r = 0;
        uint8_t g = 0;
        uint8_t b = 0;
        decode_rgb565_be(src_line + sx * 2, &r, &g, &b);
        row_rgb[static_cast<std::size_t>(dx) * 3U + 0U] = r;
        row_rgb[static_cast<std::size_t>(dx) * 3U + 1U] = g;
        row_rgb[static_cast<std::size_t>(dx) * 3U + 2U] = b;
    }

    for (int dy : dst_rows) {
        std::memcpy(det_input->ptr<uint8_t>(dy), row_rgb.data(), row_rgb.size());
    }
}

struct FrameAssembler {
    bool have_frame = false;
    bool frame_published = false;
    uint32_t current_frame = 0;
    int lines_received = 0;
    std::vector<uint8_t> line_seen;
    std::vector<uint8_t> frame_buf;
    cv::Mat det_input;
    int64_t det_preprocess_us = 0;
    SteadyClock::time_point frame_start{};

    void init() {
        line_seen.assign(kSrcHeight, 0);
        frame_buf.assign(kSrcFrameBytes, 0);
        det_input = cv::Mat::zeros(kDetInputHeight, kDetInputWidth, CV_8UC3);
    }

    void start_frame(uint32_t frame_id, SteadyClock::time_point now) {
        have_frame = true;
        frame_published = false;
        current_frame = frame_id;
        lines_received = 0;
        std::fill(line_seen.begin(), line_seen.end(), 0);
        det_input.setTo(cv::Scalar(0, 0, 0));
        det_preprocess_us = 0;
        frame_start = now;
    }
};

int find_nearest_received_line(const std::vector<uint8_t>& received_map, int target_line) {
    if (target_line < 0 || target_line >= static_cast<int>(received_map.size())) {
        return -1;
    }
    if (received_map[static_cast<std::size_t>(target_line)] != 0) {
        return target_line;
    }

    for (int dist = 1; dist < static_cast<int>(received_map.size()); ++dist) {
        if (target_line - dist >= 0 && received_map[static_cast<std::size_t>(target_line - dist)] != 0) {
            return target_line - dist;
        }
        if (target_line + dist < static_cast<int>(received_map.size()) && received_map[static_cast<std::size_t>(target_line + dist)] != 0) {
            return target_line + dist;
        }
    }
    return -1;
}

int64_t conceal_missing_lines(FrameAssembler* asmblr, const ResizePlan& plan) {
    if (!asmblr->have_frame || asmblr->lines_received <= 0) {
        return 0;
    }
    if (asmblr->lines_received == kSrcHeight) {
        return 0;
    }

    std::vector<uint8_t> received_map = asmblr->line_seen;
    int64_t concealed_lines = 0;
    for (int line_id = 0; line_id < kSrcHeight; ++line_id) {
        if (received_map[static_cast<std::size_t>(line_id)] != 0) {
            continue;
        }
        const int nearest = find_nearest_received_line(received_map, line_id);
        if (nearest < 0) {
            throw std::runtime_error("没有可用于补线的已接收行");
        }

        std::memcpy(asmblr->frame_buf.data() + static_cast<std::size_t>(line_id) * kSrcLineBytes,
                    asmblr->frame_buf.data() + static_cast<std::size_t>(nearest) * kSrcLineBytes,
                    kSrcLineBytes);
        received_map[static_cast<std::size_t>(line_id)] = 1;
        asmblr->line_seen[static_cast<std::size_t>(line_id)] = 1;

        const auto preprocess_begin = SteadyClock::now();
        process_rgb565_line_to_det_input(asmblr->frame_buf.data() + static_cast<std::size_t>(line_id) * kSrcLineBytes, line_id, plan,
                                         &asmblr->det_input);
        const auto preprocess_end = SteadyClock::now();
        asmblr->det_preprocess_us += elapsed_us(preprocess_begin, preprocess_end);
        ++concealed_lines;
    }

    asmblr->lines_received = kSrcHeight;
    return concealed_lines;
}

std::shared_ptr<RawFrameTask> publish_current_frame(FrameAssembler* asmblr,
                                                    int frame_id,
                                                    const ResizePlan& plan,
                                                    PipelineStats* stats,
                                                    UdpCounters* udp_stats) {
    if (!asmblr->have_frame || asmblr->frame_published || asmblr->lines_received <= 0) {
        return nullptr;
    }

    const int received_lines_before_conceal = asmblr->lines_received;
    int64_t concealed_lines = 0;
    bool concealed = false;
    if (asmblr->lines_received == kSrcHeight) {
        udp_stats->complete_frames.fetch_add(1, std::memory_order_relaxed);
    } else {
        concealed_lines = conceal_missing_lines(asmblr, plan);
        concealed = concealed_lines > 0;
        udp_stats->concealed_frames.fetch_add(1, std::memory_order_relaxed);
        udp_stats->concealed_lines.fetch_add(concealed_lines, std::memory_order_relaxed);
    }

    const auto finish_time = SteadyClock::now();
    const int64_t total_us = elapsed_us(asmblr->frame_start, finish_time);
    const int64_t recv_assemble_us = std::max<int64_t>(0, total_us - asmblr->det_preprocess_us);

    auto task = std::make_shared<RawFrameTask>();
    task->frame_id = frame_id;
    task->udp_frame_id = asmblr->current_frame;
    task->frame_rgb565 = std::make_shared<std::vector<uint8_t>>(asmblr->frame_buf.begin(), asmblr->frame_buf.end());
    task->det_input = asmblr->det_input.clone();
    task->source_timestamp_ms = time_point_ms(finish_time);
    task->concealed = concealed;
    task->received_lines = received_lines_before_conceal;
    task->concealed_lines = concealed_lines;
    task->read_us = total_us;
    task->recv_assemble_us = recv_assemble_us;
    task->det_preprocess_us = asmblr->det_preprocess_us;

    stats->read_count.fetch_add(1, std::memory_order_relaxed);
    stats->last_read_frame_id.store(task->frame_id, std::memory_order_relaxed);
    stats->last_udp_frame_id.store(static_cast<int>(task->udp_frame_id), std::memory_order_relaxed);
    stats->last_source_timestamp_ms.store(task->source_timestamp_ms, std::memory_order_relaxed);
    stats->last_received_lines.store(task->received_lines, std::memory_order_relaxed);
    stats->last_concealed_lines.store(task->concealed_lines, std::memory_order_relaxed);
    stats->last_concealed_flag.store(task->concealed ? 1 : 0, std::memory_order_relaxed);
    stats->last_read_us.store(task->read_us, std::memory_order_relaxed);
    stats->last_recv_assemble_us.store(task->recv_assemble_us, std::memory_order_relaxed);
    stats->last_det_preprocess_us.store(task->det_preprocess_us, std::memory_order_relaxed);

    asmblr->frame_published = true;
    return task;
}

struct X11Context {
    Display* display = nullptr;
    int screen = 0;
    Window window = 0;
    GC gc = 0;
    Atom wm_delete = 0;
    XImage* image = nullptr;
    uint32_t* rgb565_lut = nullptr;
    int bits_per_pixel = 0;
    int scale = 1;
    unsigned draw_width = 0;
    unsigned draw_height = 0;
    unsigned red_shift = 0;
    unsigned green_shift = 0;
    unsigned blue_shift = 0;
    uint32_t red_max = 0;
    uint32_t green_max = 0;
    uint32_t blue_max = 0;
    bool use_shm = false;
    XShmSegmentInfo shm_info{};
    std::vector<Pixmap> plate_glyph_pixmaps;
};

void x11_close_ctx(X11Context* x11);

unsigned mask_shift(unsigned long mask) {
    unsigned shift = 0;
    if (mask == 0) {
        return 0;
    }
    while ((mask & 1UL) == 0) {
        mask >>= 1;
        ++shift;
    }
    return shift;
}

uint32_t mask_max(unsigned long mask) {
    if (mask == 0) {
        return 0;
    }
    while ((mask & 1UL) == 0) {
        mask >>= 1;
    }
    return static_cast<uint32_t>(mask);
}

uint32_t x11_pack_rgb(const X11Context* x11, uint8_t r, uint8_t g, uint8_t b) {
    uint32_t pixel = 0;
    if (x11->red_max != 0U) {
        pixel |= (((static_cast<uint32_t>(r) * x11->red_max) + 127U) / 255U) << x11->red_shift;
    }
    if (x11->green_max != 0U) {
        pixel |= (((static_cast<uint32_t>(g) * x11->green_max) + 127U) / 255U) << x11->green_shift;
    }
    if (x11->blue_max != 0U) {
        pixel |= (((static_cast<uint32_t>(b) * x11->blue_max) + 127U) / 255U) << x11->blue_shift;
    }
    return pixel;
}

int x11_build_rgb565_lut(X11Context* x11) {
    auto* lut = static_cast<uint32_t*>(std::malloc(sizeof(uint32_t) * 65536U));
    if (lut == nullptr) {
        perror("malloc(rgb565_lut)");
        return -1;
    }

    for (uint32_t value = 0; value < 65536U; ++value) {
        uint8_t r = static_cast<uint8_t>((value >> 11) & 0x1F);
        uint8_t g = static_cast<uint8_t>((value >> 5) & 0x3F);
        uint8_t b = static_cast<uint8_t>(value & 0x1F);
        r = static_cast<uint8_t>((r << 3) | (r >> 2));
        g = static_cast<uint8_t>((g << 2) | (g >> 4));
        b = static_cast<uint8_t>((b << 3) | (b >> 2));
        lut[value] = x11_pack_rgb(x11, r, g, b);
    }

    x11->rgb565_lut = lut;
    return 0;
}

void x11_release_plate_glyph_pixmaps(X11Context* x11) {
    if (x11->display != nullptr) {
        for (Pixmap pixmap : x11->plate_glyph_pixmaps) {
            if (pixmap != 0) {
                XFreePixmap(x11->display, pixmap);
            }
        }
    }
    x11->plate_glyph_pixmaps.clear();
}

bool x11_init_plate_glyph_pixmaps(X11Context* x11) {
    x11_release_plate_glyph_pixmaps(x11);
    x11->plate_glyph_pixmaps.assign(plate_font::glyph_count(), 0);

    const plate_font::GlyphBitmap* glyphs = plate_font::glyphs();
    for (std::size_t i = 0; i < plate_font::glyph_count(); ++i) {
        const Pixmap pixmap = XCreateBitmapFromData(x11->display,
                                                    x11->window,
                                                    reinterpret_cast<const char*>(glyphs[i].bitmap),
                                                    static_cast<unsigned>(plate_font::kGlyphWidth),
                                                    static_cast<unsigned>(plate_font::kGlyphHeight));
        if (pixmap == 0) {
            std::cerr << "XCreateBitmapFromData failed for plate glyph index " << i << std::endl;
            x11_release_plate_glyph_pixmaps(x11);
            return false;
        }
        x11->plate_glyph_pixmaps[i] = pixmap;
    }
    return true;
}

int x11_open_ctx(X11Context* x11, const UdpOptions& opt) {
    Visual* visual = nullptr;
    int depth = 0;
    XEvent ev;
    bool image_ready = false;

    *x11 = X11Context{};
    x11->shm_info.shmid = -1;
    x11->shm_info.shmaddr = reinterpret_cast<char*>(-1);
    x11->scale = opt.scale;
    x11->draw_width = static_cast<unsigned>(kSrcWidth * opt.scale);
    x11->draw_height = static_cast<unsigned>(kSrcHeight * opt.scale);

    x11->display = XOpenDisplay(nullptr);
    if (x11->display == nullptr) {
        std::cerr << "XOpenDisplay failed, DISPLAY=" << (std::getenv("DISPLAY") ? std::getenv("DISPLAY") : "(null)") << std::endl;
        return -1;
    }

    x11->screen = DefaultScreen(x11->display);
    visual = DefaultVisual(x11->display, x11->screen);
    depth = DefaultDepth(x11->display, x11->screen);

    x11->window = XCreateSimpleWindow(x11->display,
                                      RootWindow(x11->display, x11->screen),
                                      0,
                                      0,
                                      x11->draw_width,
                                      x11->draw_height,
                                      1,
                                      BlackPixel(x11->display, x11->screen),
                                      BlackPixel(x11->display, x11->screen));
    if (x11->window == 0) {
        std::cerr << "XCreateSimpleWindow failed" << std::endl;
        XCloseDisplay(x11->display);
        x11->display = nullptr;
        return -1;
    }

    XSelectInput(x11->display, x11->window, ExposureMask | KeyPressMask | StructureNotifyMask);
    XStoreName(x11->display, x11->window, opt.title.c_str());
    x11->wm_delete = XInternAtom(x11->display, "WM_DELETE_WINDOW", kX11False);
    XSetWMProtocols(x11->display, x11->window, &x11->wm_delete, 1);
    x11->gc = XCreateGC(x11->display, x11->window, 0, nullptr);
    XMapWindow(x11->display, x11->window);

    do {
        XNextEvent(x11->display, &ev);
    } while (ev.type != MapNotify);

    if (XShmQueryExtension(x11->display)) {
        x11->image = XShmCreateImage(x11->display,
                                     visual,
                                     static_cast<unsigned>(depth),
                                     ZPixmap,
                                     nullptr,
                                     &x11->shm_info,
                                     x11->draw_width,
                                     x11->draw_height);
        if (x11->image != nullptr) {
            const std::size_t image_bytes = static_cast<std::size_t>(x11->image->bytes_per_line) * x11->draw_height;
            x11->shm_info.shmid = shmget(IPC_PRIVATE, image_bytes, IPC_CREAT | 0600);
            if (x11->shm_info.shmid >= 0) {
                x11->shm_info.shmaddr = static_cast<char*>(shmat(x11->shm_info.shmid, nullptr, 0));
                if (x11->shm_info.shmaddr != reinterpret_cast<char*>(-1)) {
                    x11->image->data = x11->shm_info.shmaddr;
                    x11->shm_info.readOnly = kX11False;
                    if (XShmAttach(x11->display, &x11->shm_info)) {
                        XSync(x11->display, kX11False);
                        shmctl(x11->shm_info.shmid, IPC_RMID, nullptr);
                        image_ready = true;
                        x11->use_shm = true;
                    }
                }
            }
            if (!image_ready) {
                if (x11->shm_info.shmaddr != reinterpret_cast<char*>(-1)) {
                    shmdt(x11->shm_info.shmaddr);
                    x11->shm_info.shmaddr = reinterpret_cast<char*>(-1);
                }
                if (x11->shm_info.shmid >= 0) {
                    shmctl(x11->shm_info.shmid, IPC_RMID, nullptr);
                    x11->shm_info.shmid = -1;
                }
                x11->image->data = nullptr;
                XDestroyImage(x11->image);
                x11->image = nullptr;
            }
        }
    }

    if (!image_ready) {
        x11->image = XCreateImage(x11->display,
                                  visual,
                                  static_cast<unsigned>(depth),
                                  ZPixmap,
                                  0,
                                  nullptr,
                                  x11->draw_width,
                                  x11->draw_height,
                                  32,
                                  0);
        if (x11->image == nullptr) {
            std::cerr << "XCreateImage failed" << std::endl;
            XFreeGC(x11->display, x11->gc);
            XDestroyWindow(x11->display, x11->window);
            XCloseDisplay(x11->display);
            x11->display = nullptr;
            return -1;
        }

        x11->image->data = static_cast<char*>(std::calloc(static_cast<std::size_t>(x11->image->bytes_per_line), x11->draw_height));
        if (x11->image->data == nullptr) {
            perror("calloc(ximage)");
            XDestroyImage(x11->image);
            XFreeGC(x11->display, x11->gc);
            XDestroyWindow(x11->display, x11->window);
            XCloseDisplay(x11->display);
            x11->display = nullptr;
            return -1;
        }
    }

    x11->bits_per_pixel = x11->image->bits_per_pixel;
    x11->red_shift = mask_shift(x11->image->red_mask);
    x11->green_shift = mask_shift(x11->image->green_mask);
    x11->blue_shift = mask_shift(x11->image->blue_mask);
    x11->red_max = mask_max(x11->image->red_mask);
    x11->green_max = mask_max(x11->image->green_mask);
    x11->blue_max = mask_max(x11->image->blue_mask);

    if (x11_build_rgb565_lut(x11) != 0) {
        XDestroyImage(x11->image);
        XFreeGC(x11->display, x11->gc);
        XDestroyWindow(x11->display, x11->window);
        XCloseDisplay(x11->display);
        x11->display = nullptr;
        return -1;
    }

    if (!x11_init_plate_glyph_pixmaps(x11)) {
        x11_close_ctx(x11);
        return -1;
    }

    return 0;
}

void x11_close_ctx(X11Context* x11) {
    std::free(x11->rgb565_lut);
    x11->rgb565_lut = nullptr;
    if (x11->display != nullptr && x11->use_shm) {
        XShmDetach(x11->display, &x11->shm_info);
        XSync(x11->display, kX11False);
    }
    if (x11->image != nullptr) {
        if (x11->use_shm) {
            x11->image->data = nullptr;
        }
        XDestroyImage(x11->image);
        x11->image = nullptr;
    }
    if (x11->use_shm && x11->shm_info.shmaddr != reinterpret_cast<char*>(-1)) {
        shmdt(x11->shm_info.shmaddr);
    }
    if (x11->display != nullptr) {
        x11_release_plate_glyph_pixmaps(x11);
        if (x11->gc != 0) {
            XFreeGC(x11->display, x11->gc);
        }
        if (x11->window != 0) {
            XDestroyWindow(x11->display, x11->window);
        }
        XCloseDisplay(x11->display);
        x11->display = nullptr;
    }
}

void write_x11_pixel(uint8_t* dst, uint32_t pixel, int bits_per_pixel) {
    switch (bits_per_pixel) {
    case 16:
        *reinterpret_cast<uint16_t*>(dst) = static_cast<uint16_t>(pixel);
        break;
    case 24:
        dst[0] = static_cast<uint8_t>(pixel & 0xFF);
        dst[1] = static_cast<uint8_t>((pixel >> 8) & 0xFF);
        dst[2] = static_cast<uint8_t>((pixel >> 16) & 0xFF);
        break;
    case 32:
        *reinterpret_cast<uint32_t*>(dst) = pixel;
        break;
    default:
        std::memcpy(dst, &pixel, static_cast<std::size_t>((bits_per_pixel + 7) / 8));
        break;
    }
}

void x11_draw_frame_rgb565(const X11Context* x11, const uint8_t* frame_buf) {
    const int bytes_per_pixel = (x11->bits_per_pixel + 7) / 8;
    if (bytes_per_pixel <= 0) {
        return;
    }

    if (x11->bits_per_pixel == 32 && x11->scale == 1) {
        for (unsigned sy = 0; sy < static_cast<unsigned>(kSrcHeight); ++sy) {
            const uint8_t* src_row = frame_buf + static_cast<std::size_t>(sy) * kSrcLineBytes;
            auto* dst_row = reinterpret_cast<uint32_t*>(x11->image->data + static_cast<std::size_t>(sy) * x11->image->bytes_per_line);
            for (unsigned sx = 0; sx < static_cast<unsigned>(kSrcWidth); ++sx) {
                const uint16_t rgb565 = static_cast<uint16_t>((static_cast<uint16_t>(src_row[sx * 2U]) << 8) |
                                                              static_cast<uint16_t>(src_row[sx * 2U + 1U]));
                dst_row[sx] = x11->rgb565_lut[rgb565];
            }
        }
        return;
    }

    for (unsigned sy = 0; sy < static_cast<unsigned>(kSrcHeight); ++sy) {
        const uint8_t* src_row = frame_buf + static_cast<std::size_t>(sy) * kSrcLineBytes;
        for (int vy = 0; vy < x11->scale; ++vy) {
            const unsigned dy = sy * static_cast<unsigned>(x11->scale) + static_cast<unsigned>(vy);
            auto* dst_row = reinterpret_cast<uint8_t*>(x11->image->data + static_cast<std::size_t>(dy) * x11->image->bytes_per_line);
            for (unsigned sx = 0; sx < static_cast<unsigned>(kSrcWidth); ++sx) {
                const uint16_t rgb565 = static_cast<uint16_t>((static_cast<uint16_t>(src_row[sx * 2U]) << 8) |
                                                              static_cast<uint16_t>(src_row[sx * 2U + 1U]));
                const uint32_t pixel = x11->rgb565_lut[rgb565];
                for (int vx = 0; vx < x11->scale; ++vx) {
                    const unsigned dx = sx * static_cast<unsigned>(x11->scale) + static_cast<unsigned>(vx);
                    write_x11_pixel(dst_row + dx * bytes_per_pixel, pixel, x11->bits_per_pixel);
                }
            }
        }
    }
}

void x11_present(const X11Context* x11) {
    if (x11->use_shm) {
        XShmPutImage(x11->display,
                     x11->window,
                     x11->gc,
                     x11->image,
                     0,
                     0,
                     0,
                     0,
                     x11->draw_width,
                     x11->draw_height,
                     kX11False);
    } else {
        XPutImage(x11->display, x11->window, x11->gc, x11->image, 0, 0, 0, 0, x11->draw_width, x11->draw_height);
    }
    XFlush(x11->display);
}

bool x11_handle_events(X11Context* x11, bool* need_redraw) {
    while (XPending(x11->display) > 0) {
        XEvent ev;
        XNextEvent(x11->display, &ev);
        if (ev.type == Expose) {
            *need_redraw = true;
        } else if (ev.type == ClientMessage) {
            if (static_cast<Atom>(ev.xclient.data.l[0]) == x11->wm_delete) {
                return false;
            }
        } else if (ev.type == KeyPress) {
            const KeySym sym = XLookupKeysym(&ev.xkey, 0);
            if (sym == XK_Escape || sym == XK_q || sym == XK_Q) {
                return false;
            }
        }
    }
    return true;
}

void x11_draw_text(X11Context* x11, int x, int y, const std::string& text, uint32_t color, int grow_px = 0) {
    XSetForeground(x11->display, x11->gc, color);
    if (grow_px <= 0) {
        XDrawString(x11->display, x11->window, x11->gc, x, y, text.c_str(), static_cast<int>(text.size()));
        return;
    }

    for (int dy = 0; dy <= grow_px; ++dy) {
        for (int dx = 0; dx <= grow_px; ++dx) {
            XDrawString(x11->display, x11->window, x11->gc, x + dx, y + dy, text.c_str(), static_cast<int>(text.size()));
        }
    }
}

std::size_t utf8_codepoint_length(unsigned char lead_byte) {
    if ((lead_byte & 0x80U) == 0U) {
        return 1;
    }
    if ((lead_byte & 0xE0U) == 0xC0U) {
        return 2;
    }
    if ((lead_byte & 0xF0U) == 0xE0U) {
        return 3;
    }
    if ((lead_byte & 0xF8U) == 0xF0U) {
        return 4;
    }
    return 1;
}

std::string_view next_utf8_codepoint(std::string_view text, std::size_t* pos) {
    if (pos == nullptr || *pos >= text.size()) {
        return {};
    }

    const std::size_t start = *pos;
    std::size_t length = utf8_codepoint_length(static_cast<unsigned char>(text[start]));
    if (start + length > text.size()) {
        length = 1;
    }
    *pos = start + length;
    return text.substr(start, length);
}

bool is_ascii_codepoint(std::string_view codepoint) {
    return codepoint.size() == 1 && static_cast<unsigned char>(codepoint[0]) < 0x80U;
}

int plate_text_unit_width(std::string_view codepoint) {
    return is_ascii_codepoint(codepoint) ? kPlateTextCharAdvancePx : plate_font::kGlyphWidth;
}

int plate_text_width_px(const std::string& text) {
    std::size_t pos = 0;
    int width = 0;
    bool first = true;
    const std::string_view view(text);

    while (pos < view.size()) {
        const std::string_view codepoint = next_utf8_codepoint(view, &pos);
        if (codepoint.empty()) {
            break;
        }
        if (!first) {
            width += kPlateTextCharSpacingPx;
        }
        width += plate_text_unit_width(codepoint);
        first = false;
    }

    return width;
}

void x11_draw_plate_text(X11Context* x11, int x, int top, const std::string& text, uint32_t color, uint32_t background_color) {
    int cursor_x = x;
    std::size_t pos = 0;
    const std::string_view view(text);
    const int ascii_baseline = top + kPlateTextAsciiBaselineOffset;

    while (pos < view.size()) {
        const std::string_view codepoint = next_utf8_codepoint(view, &pos);
        if (codepoint.empty()) {
            break;
        }

        if (is_ascii_codepoint(codepoint)) {
            const std::string glyph(codepoint.data(), codepoint.size());
            x11_draw_text(x11, cursor_x, ascii_baseline, glyph, color, kPlateTextGrowPx);
            cursor_x += kPlateTextCharAdvancePx;
        } else {
            const int glyph_index = plate_font::glyph_index(codepoint);
            if (glyph_index >= 0 && static_cast<std::size_t>(glyph_index) < x11->plate_glyph_pixmaps.size() &&
                x11->plate_glyph_pixmaps[static_cast<std::size_t>(glyph_index)] != 0) {
                XSetForeground(x11->display, x11->gc, color);
                XSetBackground(x11->display, x11->gc, background_color);
                XCopyPlane(x11->display,
                           x11->plate_glyph_pixmaps[static_cast<std::size_t>(glyph_index)],
                           x11->window,
                           x11->gc,
                           0,
                           0,
                           static_cast<unsigned>(plate_font::kGlyphWidth),
                           static_cast<unsigned>(plate_font::kGlyphHeight),
                           cursor_x,
                           top,
                           1UL);
            } else {
                x11_draw_text(x11, cursor_x + kPlateTextFallbackInsetX, ascii_baseline, "?", color, 0);
            }
            cursor_x += plate_font::kGlyphWidth;
        }

        if (pos < view.size()) {
            cursor_x += kPlateTextCharSpacingPx;
        }
    }
}

void x11_draw_rect(X11Context* x11, int x1, int y1, int x2, int y2, uint32_t color, int line_width = 0) {
    const int left = std::min(x1, x2);
    const int top = std::min(y1, y2);
    const int width = std::max(1, std::abs(x2 - x1));
    const int height = std::max(1, std::abs(y2 - y1));
    XSetForeground(x11->display, x11->gc, color);
    if (line_width > 0) {
        XSetLineAttributes(x11->display, x11->gc, line_width, LineSolid, CapButt, JoinMiter);
    }
    XDrawRectangle(x11->display, x11->window, x11->gc, left, top, static_cast<unsigned>(width), static_cast<unsigned>(height));
    if (line_width > 0) {
        XSetLineAttributes(x11->display, x11->gc, 0, LineSolid, CapButt, JoinMiter);
    }
}

void x11_fill_rect(X11Context* x11, int x, int y, int width, int height, uint32_t color) {
    XSetForeground(x11->display, x11->gc, color);
    XFillRectangle(x11->display,
                   x11->window,
                   x11->gc,
                   x,
                   y,
                   static_cast<unsigned>(std::max(1, width)),
                   static_cast<unsigned>(std::max(1, height)));
}

void x11_draw_overlays(X11Context* x11, const DisplayTask& task) {
    const uint32_t green = x11_pack_rgb(x11, 0, 255, 0);
    const uint32_t plate_red = x11_pack_rgb(x11, 255, 0, 0);
    const uint32_t plate_text_black = x11_pack_rgb(x11, 0, 0, 0);
    const uint32_t white = x11_pack_rgb(x11, 255, 255, 255);
    const uint32_t red = x11_pack_rgb(x11, 255, 64, 64);
    const uint32_t yellow = x11_pack_rgb(x11, 255, 255, 0);

    for (const auto& overlay : task.overlays) {
        const int left = overlay.x1 * x11->scale;
        const int top = overlay.y1 * x11->scale;
        const int right = overlay.x2 * x11->scale;
        const int bottom = overlay.y2 * x11->scale;
        x11_draw_rect(x11, left, top, right, bottom, plate_red, kPlateBoxLineWidth);
        const int text_width = std::max(1, plate_text_width_px(overlay.text));
        const int text_box_height = plate_font::kGlyphHeight + kPlateTextBgPadTop + kPlateTextBgPadBottom;
        const int text_top =
            (top - kPlateTextBaselineGap - text_box_height >= 0) ? (top - kPlateTextBaselineGap - text_box_height) : (top + kPlateTextInsideFallbackGap);
        x11_fill_rect(x11,
                      left - kPlateTextBgPadX,
                      text_top,
                      text_width + 2 * kPlateTextBgPadX,
                      text_box_height,
                      white);
        x11_draw_plate_text(x11, left, text_top + kPlateTextBgPadTop, overlay.text, plate_text_black, white);
    }

    x11_draw_text(x11, 16, 24, cv::format("FPS: %.2f", task.fps), red);
    x11_draw_text(x11,
                  16,
                  44,
                  cv::format("udp=%u recv=%d/%d concealed=%lld det=%d rec=%d",
                             task.udp_frame_id,
                             task.received_lines,
                             kSrcHeight,
                             static_cast<long long>(task.concealed_lines),
                             task.det_box_count,
                             task.recognized_plate_count),
                  task.concealed ? yellow : green);
    x11_draw_text(x11,
                  16,
                  64,
                  cv::format("read=%.2fms assemble=%.2fms det_pre=%.2fms det=%.2fms rec=%.2fms",
                             us_to_ms(task.read_us),
                             us_to_ms(task.recv_assemble_us),
                             us_to_ms(task.det_preprocess_us),
                             us_to_ms(task.det_total_us),
                             us_to_ms(task.rec_total_us)),
                  yellow);
    XFlush(x11->display);
}

void render_display_task(X11Context* x11, const DisplayTask& task) {
    x11_draw_frame_rgb565(x11, task.frame_rgb565->data());
    x11_present(x11);
    x11_draw_overlays(x11, task);
}

cv::Mat process_double_layer_plate(const cv::Mat& img) {
    const int h = img.rows;
    const int upper_end = static_cast<int>(5.0 / 12.0 * static_cast<double>(h));
    const int lower_begin = static_cast<int>(1.0 / 3.0 * static_cast<double>(h));

    const cv::Mat img_upper = img(cv::Range(0, upper_end), cv::Range::all());
    const cv::Mat img_lower = img(cv::Range(lower_begin, h), cv::Range::all());

    cv::Mat img_upper_resized;
    cv::resize(img_upper, img_upper_resized, img_lower.size(), 0.0, 0.0, cv::INTER_LINEAR);

    cv::Mat merged;
    std::vector<cv::Mat> parts = {img_upper_resized, img_lower};
    cv::hconcat(parts, merged);
    return merged;
}

bool collect_plate_indices(const plate::OutputTensor& output, std::vector<int64_t>* indices, std::string* error_message) {
    if (indices == nullptr) {
        if (error_message != nullptr) {
            *error_message = "识别输出索引容器为空";
        }
        return false;
    }

    std::vector<int> dims = output.shape.dims;
    if (!dims.empty() && dims.front() == 1) {
        dims.erase(dims.begin());
    }
    while (dims.size() > 2) {
        auto it = std::find(dims.begin(), dims.end(), 1);
        if (it == dims.end()) {
            break;
        }
        dims.erase(it);
    }

    if (dims.size() != 2) {
        if (error_message != nullptr) {
            *error_message = "识别输出维度不符合 swapaxes+argmax 的静态假设";
        }
        return false;
    }

    const int time_steps = dims[0];
    const int class_count = dims[1];
    if (time_steps <= 0 || class_count <= 0 || output.values.size() < static_cast<std::size_t>(time_steps * class_count)) {
        if (error_message != nullptr) {
            *error_message = "识别输出元素数量不足";
        }
        return false;
    }

    indices->clear();
    indices->reserve(static_cast<std::size_t>(time_steps));
    for (int t = 0; t < time_steps; ++t) {
        int best_index = 0;
        float best_value = output.values[static_cast<std::size_t>(t * class_count)];
        for (int cls = 1; cls < class_count; ++cls) {
            const float value = output.values[static_cast<std::size_t>(t * class_count + cls)];
            if (value > best_value) {
                best_value = value;
                best_index = cls;
            }
        }
        indices->push_back(best_index);
    }
    return true;
}

std::vector<plate::Detection> postprocess_detector_outputs(const std::vector<plate::OutputTensor>& outputs) {
    if (outputs.empty()) {
        throw std::runtime_error("检测模型没有返回输出张量");
    }

    std::string error_message;
    auto dets = plate::postprocess_fastestdet_output_tensor(outputs[0], kConfThres, kNmsThres, kDetNumClasses, &error_message);
    if (!error_message.empty()) {
        throw std::runtime_error(error_message);
    }
    return dets;
}

cv::Mat rgb565_roi_to_bgr(const std::vector<uint8_t>& frame_rgb565, int x1, int y1, int x2, int y2) {
    const int roi_w = x2 - x1;
    const int roi_h = y2 - y1;
    cv::Mat roi(roi_h, roi_w, CV_8UC3);
    for (int y = 0; y < roi_h; ++y) {
        const uint8_t* src_row = frame_rgb565.data() + static_cast<std::size_t>(y1 + y) * kSrcLineBytes;
        uint8_t* dst_row = roi.ptr<uint8_t>(y);
        for (int x = 0; x < roi_w; ++x) {
            uint8_t r = 0;
            uint8_t g = 0;
            uint8_t b = 0;
            decode_rgb565_be(src_row + static_cast<std::size_t>(x1 + x) * 2U, &r, &g, &b);
            dst_row[x * 3 + 0] = b;
            dst_row[x * 3 + 1] = g;
            dst_row[x * 3 + 2] = r;
        }
    }
    return roi;
}

void read_worker_udp(const UdpOptions& opt,
                     const ResizePlan& resize_plan,
                     LatestQueue<std::shared_ptr<RawFrameTask>>* read_queue,
                     std::atomic<bool>* stop_event,
                     ErrorState* error_state,
                     PipelineStats* stats,
                     UdpCounters* udp_stats) {
    const int sock = create_socket(opt);
    if (sock < 0) {
        error_state->set_once("read thread error: 创建 UDP socket 失败");
        stop_event->store(true);
        read_queue->push_latest(nullptr);
        return;
    }

    FrameAssembler asmblr;
    asmblr.init();
    int frame_id = 0;

    try {
        pollfd pfd{};
        pfd.fd = sock;
        pfd.events = POLLIN;

        while (!stop_event->load()) {
            const int pr = poll(&pfd, 1, 100);
            if (pr < 0) {
                if (errno == EINTR) {
                    continue;
                }
                throw std::runtime_error(std::string("poll 失败: ") + std::strerror(errno));
            }
            if (pr > 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) {
                throw std::runtime_error(cv::format("poll revents=0x%x", pfd.revents));
            }
            if (!(pr > 0 && (pfd.revents & POLLIN))) {
                continue;
            }

            for (;;) {
                uint8_t packet[kMaxUdpPayload];
                sockaddr_in peer{};
                socklen_t peer_len = sizeof(peer);
                const ssize_t n = recvfrom(sock, packet, sizeof(packet), 0, reinterpret_cast<sockaddr*>(&peer), &peer_len);
                if (n < 0) {
                    if (errno == EAGAIN || errno == EWOULDBLOCK) {
                        break;
                    }
                    if (errno == EINTR) {
                        continue;
                    }
                    throw std::runtime_error(std::string("recvfrom 失败: ") + std::strerror(errno));
                }

                udp_stats->packets_total.fetch_add(1, std::memory_order_relaxed);

                if (opt.has_source_ip && peer.sin_addr.s_addr != opt.source_ip.s_addr) {
                    continue;
                }
                if (opt.source_port != 0 && ntohs(peer.sin_port) != opt.source_port) {
                    continue;
                }
                udp_stats->packets_filtered_in.fetch_add(1, std::memory_order_relaxed);

                if (n < kHeaderBytes || n != kExpectedPayload) {
                    udp_stats->packets_bad_size.fetch_add(1, std::memory_order_relaxed);
                    continue;
                }
                udp_stats->packets_payload_ok.fetch_add(1, std::memory_order_relaxed);

                const uint32_t udp_frame_id = read_be32(packet + 0);
                const uint16_t line_id = read_be16(packet + 4);
                if (line_id >= kSrcHeight) {
                    udp_stats->packets_bad_line.fetch_add(1, std::memory_order_relaxed);
                    continue;
                }

                const auto packet_now = SteadyClock::now();
                if (!asmblr.have_frame) {
                    asmblr.start_frame(udp_frame_id, packet_now);
                    udp_stats->current_frame_id.store(static_cast<int>(udp_frame_id), std::memory_order_relaxed);
                    udp_stats->current_lines_received.store(0, std::memory_order_relaxed);
                } else if (udp_frame_id != asmblr.current_frame) {
                    if (static_cast<int32_t>(udp_frame_id - asmblr.current_frame) < 0) {
                        udp_stats->old_frame_packets.fetch_add(1, std::memory_order_relaxed);
                        continue;
                    }

                    auto task = publish_current_frame(&asmblr, frame_id, resize_plan, stats, udp_stats);
                    if (task != nullptr) {
                        read_queue->push_latest(task);
                        ++frame_id;
                    }
                    asmblr.start_frame(udp_frame_id, packet_now);
                    udp_stats->current_frame_id.store(static_cast<int>(udp_frame_id), std::memory_order_relaxed);
                    udp_stats->current_lines_received.store(0, std::memory_order_relaxed);
                }

                if (asmblr.line_seen[static_cast<std::size_t>(line_id)] != 0) {
                    udp_stats->duplicates.fetch_add(1, std::memory_order_relaxed);
                    continue;
                }

                std::memcpy(asmblr.frame_buf.data() + static_cast<std::size_t>(line_id) * kSrcLineBytes,
                            packet + kHeaderBytes,
                            kSrcLineBytes);
                asmblr.line_seen[static_cast<std::size_t>(line_id)] = 1;
                ++asmblr.lines_received;
                udp_stats->current_lines_received.store(asmblr.lines_received, std::memory_order_relaxed);

                const auto preprocess_begin = SteadyClock::now();
                process_rgb565_line_to_det_input(packet + kHeaderBytes, line_id, resize_plan, &asmblr.det_input);
                const auto preprocess_end = SteadyClock::now();
                asmblr.det_preprocess_us += elapsed_us(preprocess_begin, preprocess_end);

                if (asmblr.lines_received == kSrcHeight && !asmblr.frame_published) {
                    auto task = publish_current_frame(&asmblr, frame_id, resize_plan, stats, udp_stats);
                    if (task != nullptr) {
                        read_queue->push_latest(task);
                        ++frame_id;
                    }
                }
            }
        }

        if (asmblr.have_frame && !asmblr.frame_published && asmblr.lines_received > 0) {
            auto task = publish_current_frame(&asmblr, frame_id, resize_plan, stats, udp_stats);
            if (task != nullptr) {
                read_queue->push_latest(task);
            }
        }
    } catch (const std::exception& exc) {
        error_state->set_once(std::string("read thread error: ") + exc.what());
        stop_event->store(true);
    }

    close(sock);
    read_queue->push_latest(nullptr);
}

void detect_worker(plate::RknnRuntime* detector,
                   LatestQueue<std::shared_ptr<RawFrameTask>>* read_queue,
                   LatestQueue<std::shared_ptr<FrameTask>>* detect_queue,
                   DetOutputPool* det_output_pool,
                   std::atomic<bool>* stop_event,
                   ErrorState* error_state,
                   PipelineStats* stats) {
    plate::InferOptions det_infer_options;
    det_infer_options.prefer_pass_through = true;
    det_infer_options.want_float_output = false;
    det_infer_options.prefer_prealloc_output = true;

    try {
        while (!stop_event->load()) {
            std::shared_ptr<RawFrameTask> raw_task;
            if (!read_queue->wait_pop_for(&raw_task, std::chrono::milliseconds(100))) {
                continue;
            }
            if (!raw_task) {
                break;
            }

            auto det_bundle = det_output_pool->acquire();
            std::string infer_error;
            if (!detector->infer_u8_nhwc_ex(raw_task->det_input.data,
                                            raw_task->det_input.total() * raw_task->det_input.elemSize(),
                                            det_infer_options,
                                            &det_bundle->outputs,
                                            &det_bundle->profile,
                                            &infer_error)) {
                throw std::runtime_error(infer_error);
            }

            auto task = std::make_shared<FrameTask>();
            task->frame_id = raw_task->frame_id;
            task->udp_frame_id = raw_task->udp_frame_id;
            task->frame_rgb565 = raw_task->frame_rgb565;
            task->det_bundle = std::move(det_bundle);
            task->source_timestamp_ms = raw_task->source_timestamp_ms;
            task->concealed = raw_task->concealed;
            task->received_lines = raw_task->received_lines;
            task->concealed_lines = raw_task->concealed_lines;
            task->read_us = raw_task->read_us;
            task->recv_assemble_us = raw_task->recv_assemble_us;
            task->det_preprocess_us = raw_task->det_preprocess_us;
            task->det_inputs_set_us = task->det_bundle->profile.inputs_set_us;
            task->det_run_api_us = task->det_bundle->profile.run_us;
            task->det_outputs_get_us = task->det_bundle->profile.outputs_get_us;
            task->det_outputs_release_us = task->det_bundle->profile.outputs_release_us;
            task->det_npu_run_us = task->det_bundle->profile.npu_run_duration_us;
            task->det_pass_through_enabled = task->det_bundle->profile.used_pass_through ? 1 : 0;
            task->det_infer_us = task->det_bundle->profile.total_us;

            stats->detect_count.fetch_add(1, std::memory_order_relaxed);
            stats->last_det_inputs_set_us.store(task->det_inputs_set_us, std::memory_order_relaxed);
            stats->last_det_run_api_us.store(task->det_run_api_us, std::memory_order_relaxed);
            stats->last_det_outputs_get_us.store(task->det_outputs_get_us, std::memory_order_relaxed);
            stats->last_det_outputs_release_us.store(task->det_outputs_release_us, std::memory_order_relaxed);
            stats->last_det_npu_run_us.store(task->det_npu_run_us, std::memory_order_relaxed);
            stats->last_det_pass_through.store(task->det_pass_through_enabled, std::memory_order_relaxed);
            stats->last_det_infer_us.store(task->det_infer_us, std::memory_order_relaxed);
            update_jump_stat(&stats->last_detect_frame_id, &stats->last_detect_jump, &stats->max_detect_jump, task->frame_id);

            detect_queue->push_latest(task);
        }
    } catch (const std::exception& exc) {
        error_state->set_once(std::string("detect thread error: ") + exc.what());
        stop_event->store(true);
    }
    detect_queue->push_latest(nullptr);
}

void rec_worker(plate::RknnRuntime* recognizer,
                LatestQueue<std::shared_ptr<FrameTask>>* detect_queue,
                LatestQueue<std::shared_ptr<DisplayTask>>* display_queue,
                std::atomic<bool>* stop_event,
                ErrorState* error_state,
                PipelineStats* stats) {
    auto prev_time = SteadyClock::now();
    try {
        while (!stop_event->load()) {
            std::shared_ptr<FrameTask> task;
            if (!detect_queue->wait_pop_for(&task, std::chrono::milliseconds(100))) {
                continue;
            }
            if (!task) {
                break;
            }

            const auto rec_begin = SteadyClock::now();
            const auto det_post_begin = SteadyClock::now();
            if (!task->det_bundle) {
                throw std::runtime_error("检测输出 bundle 为空");
            }
            auto det_boxes = postprocess_detector_outputs(task->det_bundle->outputs);
            const auto det_post_end = SteadyClock::now();
            task->det_post_us = elapsed_us(det_post_begin, det_post_end);
            task->det_total_us = task->det_preprocess_us + task->det_infer_us + task->det_post_us;

            int64_t rec_preprocess_us = 0;
            int64_t rec_infer_us = 0;
            int64_t rec_decode_us = 0;
            int64_t rec_draw_us = 0;
            int recognized_plate_count = 0;
            std::vector<OverlayItem> overlays;
            overlays.reserve(det_boxes.size());

            const auto& frame_rgb565 = *task->frame_rgb565;
            for (const auto& det : det_boxes) {
                const int x1 = std::clamp(static_cast<int>(det.x1 * kSrcWidth), 0, kSrcWidth);
                const int y1 = std::clamp(static_cast<int>(det.y1 * kSrcHeight), 0, kSrcHeight);
                const int x2 = std::clamp(static_cast<int>(det.x2 * kSrcWidth), 0, kSrcWidth);
                const int y2 = std::clamp(static_cast<int>(det.y2 * kSrcHeight), 0, kSrcHeight);
                if (x2 <= x1 || y2 <= y1) {
                    continue;
                }

                const auto rec_preprocess_begin = SteadyClock::now();
                cv::Mat plate_img = rgb565_roi_to_bgr(frame_rgb565, x1, y1, x2, y2);
                if (plate_img.empty()) {
                    continue;
                }
                if (det.cls == 1) {
                    plate_img = process_double_layer_plate(plate_img);
                }

                cv::Mat plate_resized;
                cv::resize(plate_img, plate_resized, cv::Size(kRecInputWidth, kRecInputHeight), 0.0, 0.0, cv::INTER_LINEAR);
                const auto rec_preprocess_end = SteadyClock::now();
                rec_preprocess_us += elapsed_us(rec_preprocess_begin, rec_preprocess_end);

                std::vector<plate::OutputTensor> rec_outputs;
                std::string infer_error;
                const auto rec_infer_begin = SteadyClock::now();
                if (!recognizer->infer_u8_nhwc(plate_resized.data,
                                               plate_resized.total() * plate_resized.elemSize(),
                                               &rec_outputs,
                                               &infer_error)) {
                    throw std::runtime_error(infer_error);
                }
                const auto rec_infer_end = SteadyClock::now();
                rec_infer_us += elapsed_us(rec_infer_begin, rec_infer_end);
                if (rec_outputs.empty()) {
                    continue;
                }

                std::vector<int64_t> indices;
                std::string decode_error;
                const auto rec_decode_begin = SteadyClock::now();
                if (!collect_plate_indices(rec_outputs[0], &indices, &decode_error)) {
                    throw std::runtime_error(decode_error);
                }
                const std::string plate_utf8 = plate::decode_plate_utf8(indices);
                const auto rec_decode_end = SteadyClock::now();
                rec_decode_us += elapsed_us(rec_decode_begin, rec_decode_end);

                const auto rec_draw_begin = SteadyClock::now();
                OverlayItem overlay;
                overlay.x1 = x1;
                overlay.y1 = y1;
                overlay.x2 = x2;
                overlay.y2 = y2;
                overlay.text = plate_utf8;
                overlays.push_back(std::move(overlay));
                const auto rec_draw_end = SteadyClock::now();
                rec_draw_us += elapsed_us(rec_draw_begin, rec_draw_end);
                ++recognized_plate_count;
            }

            const auto current_time = SteadyClock::now();
            const double fps = 1.0 / std::max(std::chrono::duration<double>(current_time - prev_time).count(), 1e-6);
            prev_time = current_time;

            const auto rec_end = SteadyClock::now();
            const int64_t rec_total_us = elapsed_us(rec_begin, rec_end);
            stats->recognize_count.fetch_add(1, std::memory_order_relaxed);
            stats->last_det_box_count.store(static_cast<int>(det_boxes.size()), std::memory_order_relaxed);
            stats->last_det_preprocess_us.store(task->det_preprocess_us, std::memory_order_relaxed);
            stats->last_det_inputs_set_us.store(task->det_inputs_set_us, std::memory_order_relaxed);
            stats->last_det_run_api_us.store(task->det_run_api_us, std::memory_order_relaxed);
            stats->last_det_outputs_get_us.store(task->det_outputs_get_us, std::memory_order_relaxed);
            stats->last_det_outputs_release_us.store(task->det_outputs_release_us, std::memory_order_relaxed);
            stats->last_det_npu_run_us.store(task->det_npu_run_us, std::memory_order_relaxed);
            stats->last_det_pass_through.store(task->det_pass_through_enabled, std::memory_order_relaxed);
            stats->last_det_post_us.store(task->det_post_us, std::memory_order_relaxed);
            stats->last_det_total_us.store(task->det_total_us, std::memory_order_relaxed);
            stats->last_recognized_plate_count.store(recognized_plate_count, std::memory_order_relaxed);
            stats->last_rec_preprocess_us.store(rec_preprocess_us, std::memory_order_relaxed);
            stats->last_rec_infer_us.store(rec_infer_us, std::memory_order_relaxed);
            stats->last_rec_decode_us.store(rec_decode_us, std::memory_order_relaxed);
            stats->last_rec_draw_us.store(rec_draw_us, std::memory_order_relaxed);
            stats->last_rec_total_us.store(rec_total_us, std::memory_order_relaxed);
            update_jump_stat(&stats->last_recognize_frame_id, &stats->last_recognize_jump, &stats->max_recognize_jump, task->frame_id);

            auto display_task = std::make_shared<DisplayTask>();
            display_task->frame_id = task->frame_id;
            display_task->udp_frame_id = task->udp_frame_id;
            display_task->frame_rgb565 = task->frame_rgb565;
            display_task->overlays = std::move(overlays);
            display_task->source_timestamp_ms = task->source_timestamp_ms;
            display_task->concealed = task->concealed;
            display_task->received_lines = task->received_lines;
            display_task->concealed_lines = task->concealed_lines;
            display_task->det_box_count = static_cast<int>(det_boxes.size());
            display_task->recognized_plate_count = recognized_plate_count;
            display_task->fps = fps;
            display_task->read_us = task->read_us;
            display_task->recv_assemble_us = task->recv_assemble_us;
            display_task->det_preprocess_us = task->det_preprocess_us;
            display_task->det_inputs_set_us = task->det_inputs_set_us;
            display_task->det_run_api_us = task->det_run_api_us;
            display_task->det_outputs_get_us = task->det_outputs_get_us;
            display_task->det_outputs_release_us = task->det_outputs_release_us;
            display_task->det_npu_run_us = task->det_npu_run_us;
            display_task->det_pass_through_enabled = task->det_pass_through_enabled;
            display_task->det_infer_us = task->det_infer_us;
            display_task->det_post_us = task->det_post_us;
            display_task->det_total_us = task->det_total_us;
            display_task->rec_preprocess_us = rec_preprocess_us;
            display_task->rec_infer_us = rec_infer_us;
            display_task->rec_decode_us = rec_decode_us;
            display_task->rec_draw_us = rec_draw_us;
            display_task->rec_total_us = rec_total_us;
            display_queue->push_latest(display_task);
        }
    } catch (const std::exception& exc) {
        error_state->set_once(std::string("rec thread error: ") + exc.what());
        stop_event->store(true);
    }
    display_queue->push_latest(nullptr);
}

void print_debug_report(const PipelineStats& pipeline_stats,
                        const UdpCounters& udp_stats,
                        const QueueStats& read_queue_stats,
                        const QueueStats& detect_queue_stats,
                        const QueueStats& display_queue_stats,
                        double wall_elapsed_sec) {
    const double read_fps = pipeline_stats.read_count.load(std::memory_order_relaxed) / std::max(wall_elapsed_sec, 1e-6);
    const double detect_fps = pipeline_stats.detect_count.load(std::memory_order_relaxed) / std::max(wall_elapsed_sec, 1e-6);
    const double rec_fps = pipeline_stats.recognize_count.load(std::memory_order_relaxed) / std::max(wall_elapsed_sec, 1e-6);
    const double display_fps = pipeline_stats.display_count.load(std::memory_order_relaxed) / std::max(wall_elapsed_sec, 1e-6);

    std::cout << "[debug] fps avg(read/det/rec/show)="
              << cv::format("%.2f / %.2f / %.2f / %.2f", read_fps, detect_fps, rec_fps, display_fps) << std::endl;
    std::cout << "[debug] progress wall=" << cv::format("%.2fs", wall_elapsed_sec)
              << ", last_frame(read/det/rec/show)=" << pipeline_stats.last_read_frame_id.load(std::memory_order_relaxed) << "/"
              << pipeline_stats.last_detect_frame_id.load(std::memory_order_relaxed) << "/"
              << pipeline_stats.last_recognize_frame_id.load(std::memory_order_relaxed) << "/"
              << pipeline_stats.last_display_frame_id.load(std::memory_order_relaxed)
              << ", udp=" << pipeline_stats.last_udp_frame_id.load(std::memory_order_relaxed)
              << std::endl;
    std::cout << "[debug] jump(det/rec/show)=" << pipeline_stats.last_detect_jump.load(std::memory_order_relaxed) << "/"
              << pipeline_stats.last_recognize_jump.load(std::memory_order_relaxed) << "/"
              << pipeline_stats.last_display_jump.load(std::memory_order_relaxed) << ", max="
              << pipeline_stats.max_detect_jump.load(std::memory_order_relaxed) << "/"
              << pipeline_stats.max_recognize_jump.load(std::memory_order_relaxed) << "/"
              << pipeline_stats.max_display_jump.load(std::memory_order_relaxed) << std::endl;
    std::cout << "[debug] queue read(push/pop/overwrite/timeout)=" << read_queue_stats.push_count.load(std::memory_order_relaxed) << "/"
              << read_queue_stats.pop_count.load(std::memory_order_relaxed) << "/"
              << read_queue_stats.overwrite_count.load(std::memory_order_relaxed) << "/"
              << read_queue_stats.timeout_count.load(std::memory_order_relaxed)
              << ", detect(push/pop/overwrite/timeout)=" << detect_queue_stats.push_count.load(std::memory_order_relaxed) << "/"
              << detect_queue_stats.pop_count.load(std::memory_order_relaxed) << "/"
              << detect_queue_stats.overwrite_count.load(std::memory_order_relaxed) << "/"
              << detect_queue_stats.timeout_count.load(std::memory_order_relaxed)
              << ", display(push/pop/overwrite/timeout)=" << display_queue_stats.push_count.load(std::memory_order_relaxed) << "/"
              << display_queue_stats.pop_count.load(std::memory_order_relaxed) << "/"
              << display_queue_stats.overwrite_count.load(std::memory_order_relaxed) << "/"
              << display_queue_stats.timeout_count.load(std::memory_order_relaxed) << std::endl;
    std::cout << "[debug] udp packets(total/filter/payload)="
              << udp_stats.packets_total.load(std::memory_order_relaxed) << "/"
              << udp_stats.packets_filtered_in.load(std::memory_order_relaxed) << "/"
              << udp_stats.packets_payload_ok.load(std::memory_order_relaxed)
              << ", full=" << udp_stats.complete_frames.load(std::memory_order_relaxed)
              << ", concealed=" << udp_stats.concealed_frames.load(std::memory_order_relaxed)
              << ", concealed_lines=" << udp_stats.concealed_lines.load(std::memory_order_relaxed)
              << ", dup=" << udp_stats.duplicates.load(std::memory_order_relaxed)
              << ", bad_size=" << udp_stats.packets_bad_size.load(std::memory_order_relaxed)
              << ", bad_line=" << udp_stats.packets_bad_line.load(std::memory_order_relaxed)
              << ", old=" << udp_stats.old_frame_packets.load(std::memory_order_relaxed)
              << ", cur_frame=" << udp_stats.current_frame_id.load(std::memory_order_relaxed)
              << ", lines=" << udp_stats.current_lines_received.load(std::memory_order_relaxed) << "/" << kSrcHeight
              << std::endl;
    std::cout << "[debug] read-thread "
              << cv::format("total=%.2fms recv_assemble=%.2fms det_preprocess=%.2fms lines=%d/%d concealed=%d(%lld)",
                            us_to_ms(pipeline_stats.last_read_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_recv_assemble_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_det_preprocess_us.load(std::memory_order_relaxed)),
                            pipeline_stats.last_received_lines.load(std::memory_order_relaxed),
                            kSrcHeight,
                            pipeline_stats.last_concealed_flag.load(std::memory_order_relaxed),
                            static_cast<long long>(pipeline_stats.last_concealed_lines.load(std::memory_order_relaxed)))
              << std::endl;
    std::cout << "[debug] detect-thread "
              << cv::format("pass=%d total=%.2fms inputs_set=%.2fms run_api=%.2fms npu_run=%.2fms outputs_get=%.2fms release=%.2fms",
                            pipeline_stats.last_det_pass_through.load(std::memory_order_relaxed),
                            us_to_ms(pipeline_stats.last_det_infer_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_det_inputs_set_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_det_run_api_us.load(std::memory_order_relaxed)),
                            metric_us_to_ms(pipeline_stats.last_det_npu_run_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_det_outputs_get_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_det_outputs_release_us.load(std::memory_order_relaxed)))
              << std::endl;
    std::cout << "[debug] det-pipeline(boxes=" << pipeline_stats.last_det_box_count.load(std::memory_order_relaxed) << ") "
              << cv::format("total=%.2fms preprocess=%.2fms infer=%.2fms post=%.2fms",
                            us_to_ms(pipeline_stats.last_det_total_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_det_preprocess_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_det_infer_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_det_post_us.load(std::memory_order_relaxed)))
              << std::endl;
    std::cout << "[debug] rec-thread(plates=" << pipeline_stats.last_recognized_plate_count.load(std::memory_order_relaxed) << ") "
              << cv::format("total=%.2fms preprocess=%.2fms infer=%.2fms decode=%.2fms draw=%.2fms",
                            us_to_ms(pipeline_stats.last_rec_total_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_rec_preprocess_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_rec_infer_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_rec_decode_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_rec_draw_us.load(std::memory_order_relaxed)))
              << std::endl;
    std::cout << "[debug] display-thread "
              << cv::format("draw=%.2fms present=%.2fms overlay=%.2fms event=%.2fms total=%.2fms",
                            us_to_ms(pipeline_stats.last_display_draw_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_display_present_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_display_overlay_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_display_event_us.load(std::memory_order_relaxed)),
                            us_to_ms(pipeline_stats.last_display_total_us.load(std::memory_order_relaxed)))
              << std::endl;
}

void print_model_summary(const char* name, const plate::RknnRuntime& runtime) {
    std::cout << "--> " << name << " sdk=" << runtime.sdk_api_version()
              << ", driver=" << runtime.sdk_driver_version() << std::endl;
    std::cout << "    input:        " << describe_tensor_shape(runtime.input_attr()) << std::endl;
    std::cout << "    native input: " << describe_tensor_shape(runtime.native_input_attr()) << std::endl;
    for (std::size_t i = 0; i < runtime.output_attrs().size(); ++i) {
        std::cout << "    output[" << i << "]:      " << describe_tensor_shape(runtime.output_attrs()[i]) << std::endl;
        if (i < runtime.native_output_attrs().size()) {
            std::cout << "    native output[" << i << "]: " << describe_tensor_shape(runtime.native_output_attrs()[i]) << std::endl;
        }
    }
}

}  // namespace

int main(int argc, char** argv) {
    UdpOptions opt;
    std::string error_message;
    const ParseResult parse_result = parse_options(argc, argv, &opt, &error_message);
    if (parse_result == ParseResult::kHelp) {
        return 0;
    }
    if (parse_result == ParseResult::kError) {
        std::cerr << error_message << std::endl;
        return 1;
    }

    plate::RknnRuntime rknn_det;
    plate::RknnRuntime rknn_rec;

    std::cout << "--> Loading models" << std::endl;
    if (!rknn_det.load_model(kDetRknnPath, &error_message)) {
        std::cerr << error_message << std::endl;
        return 1;
    }
    if (!rknn_rec.load_model(kRecRknnPath, &error_message)) {
        std::cerr << error_message << std::endl;
        return 1;
    }
    std::cout << "done" << std::endl;
    print_model_summary("detector", rknn_det);
    print_model_summary("recognizer", rknn_rec);
    std::cout << "--> Detector pass_through fast-path: " << (can_use_detector_pass_through(rknn_det) ? "enabled" : "disabled") << std::endl;

    X11Context x11;
    if (x11_open_ctx(&x11, opt) != 0) {
        return 1;
    }

    std::cout << "--> Source info: udp=" << opt.bind_ip << ":" << opt.port << ", size=" << kSrcWidth << "x" << kSrcHeight
              << ", payload=" << kExpectedPayload << ", scale=" << opt.scale << std::endl;
    std::cout << "--> Postprocess backend: C++" << std::endl;
    std::cout << "--> Pipeline mode: udp read(recv+assemble+rgb565->352rgb) thread / detect(infer) thread / rec(postprocess+rgb565 roi+recognize) thread / main-thread x11 display"
              << std::endl;

    QueueStats read_queue_stats;
    QueueStats detect_queue_stats;
    QueueStats display_queue_stats;
    UdpCounters udp_stats;
    PipelineStats pipeline_stats;
    LatestQueue<std::shared_ptr<RawFrameTask>> read_queue(&read_queue_stats);
    LatestQueue<std::shared_ptr<FrameTask>> detect_queue(&detect_queue_stats);
    LatestQueue<std::shared_ptr<DisplayTask>> display_queue(&display_queue_stats);
    DetOutputPool det_output_pool(kDetOutputPoolCapacity);
    std::atomic<bool> stop_event{false};
    ErrorState error_state;
    const ResizePlan resize_plan = build_resize_plan(kSrcWidth, kSrcHeight, kDetInputWidth, kDetInputHeight);

    std::thread read_thread(read_worker_udp, std::cref(opt), std::cref(resize_plan), &read_queue, &stop_event, &error_state, &pipeline_stats,
                            &udp_stats);
    std::thread detect_thread(detect_worker, &rknn_det, &read_queue, &detect_queue, &det_output_pool, &stop_event, &error_state, &pipeline_stats);
    std::thread rec_thread(rec_worker, &rknn_rec, &detect_queue, &display_queue, &stop_event, &error_state, &pipeline_stats);

    const auto wall_start = SteadyClock::now();
    auto last_report_time = wall_start;
    bool need_redraw = false;
    std::shared_ptr<DisplayTask> last_display_task;

    try {
        while (!stop_event.load()) {
            std::shared_ptr<DisplayTask> display_task;
            if (!display_queue.wait_pop_for(&display_task, std::chrono::milliseconds(100))) {
                const auto event_begin = SteadyClock::now();
                const bool keep_running = x11_handle_events(&x11, &need_redraw);
                const auto event_end = SteadyClock::now();
                pipeline_stats.last_display_event_us.store(elapsed_us(event_begin, event_end), std::memory_order_relaxed);

                if (!keep_running) {
                    stop_event.store(true);
                    break;
                }
                if (need_redraw && last_display_task != nullptr) {
                    const auto redraw_begin = SteadyClock::now();
                    render_display_task(&x11, *last_display_task);
                    const auto redraw_end = SteadyClock::now();
                    pipeline_stats.last_display_total_us.store(elapsed_us(redraw_begin, redraw_end), std::memory_order_relaxed);
                    need_redraw = false;
                }

                const auto now = SteadyClock::now();
                if (std::chrono::duration<double>(now - last_report_time).count() >= opt.report_interval_sec) {
                    const double wall_elapsed_sec = std::chrono::duration<double>(now - wall_start).count();
                    print_debug_report(pipeline_stats, udp_stats, read_queue_stats, detect_queue_stats, display_queue_stats, wall_elapsed_sec);
                    last_report_time = now;
                }
                continue;
            }
            if (!display_task) {
                break;
            }

            const auto display_begin = SteadyClock::now();
            pipeline_stats.display_count.fetch_add(1, std::memory_order_relaxed);
            update_jump_stat(&pipeline_stats.last_display_frame_id, &pipeline_stats.last_display_jump, &pipeline_stats.max_display_jump,
                             display_task->frame_id);

            const auto draw_begin = SteadyClock::now();
            x11_draw_frame_rgb565(&x11, display_task->frame_rgb565->data());
            const auto draw_end = SteadyClock::now();

            const auto present_begin = SteadyClock::now();
            x11_present(&x11);
            const auto present_end = SteadyClock::now();

            const auto overlay_begin = SteadyClock::now();
            x11_draw_overlays(&x11, *display_task);
            const auto overlay_end = SteadyClock::now();

            const auto event_begin = SteadyClock::now();
            const bool keep_running = x11_handle_events(&x11, &need_redraw);
            const auto event_end = SteadyClock::now();

            pipeline_stats.last_display_draw_us.store(elapsed_us(draw_begin, draw_end), std::memory_order_relaxed);
            pipeline_stats.last_display_present_us.store(elapsed_us(present_begin, present_end), std::memory_order_relaxed);
            pipeline_stats.last_display_overlay_us.store(elapsed_us(overlay_begin, overlay_end), std::memory_order_relaxed);
            pipeline_stats.last_display_event_us.store(elapsed_us(event_begin, event_end), std::memory_order_relaxed);
            pipeline_stats.last_display_total_us.store(elapsed_us(display_begin, event_end), std::memory_order_relaxed);

            last_display_task = display_task;
            need_redraw = false;

            const auto now = SteadyClock::now();
            if (std::chrono::duration<double>(now - last_report_time).count() >= opt.report_interval_sec) {
                const double wall_elapsed_sec = std::chrono::duration<double>(now - wall_start).count();
                print_debug_report(pipeline_stats, udp_stats, read_queue_stats, detect_queue_stats, display_queue_stats, wall_elapsed_sec);
                last_report_time = now;
            }

            if (!keep_running) {
                stop_event.store(true);
                break;
            }
        }
    } catch (const std::exception& exc) {
        error_state.set_once(std::string("main thread error: ") + exc.what());
        stop_event.store(true);
    }

    stop_event.store(true);
    if (read_thread.joinable()) {
        read_thread.join();
    }
    if (detect_thread.joinable()) {
        detect_thread.join();
    }
    if (rec_thread.joinable()) {
        rec_thread.join();
    }
    x11_close_ctx(&x11);
    rknn_det.release();
    rknn_rec.release();

    const std::string final_error = error_state.get();
    if (!final_error.empty()) {
        std::cerr << final_error << std::endl;
    }
    std::cout << "done" << std::endl;
    return final_error.empty() ? 0 : 1;
}
