#include "imgui.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {
constexpr int kWarmupDefault = 300;
constexpr int kFramesDefault = 2000;
constexpr int kVirtualRows = 40;
constexpr int kVirtualOverscan = 2;
constexpr std::uint64_t kFnvBasis = 1469598103934665603ULL;
constexpr std::uint64_t kFnvPrime = 1099511628211ULL;

struct Options {
    std::string workload = "labels_repeated";
    int scale = 100;
    int warmup = kWarmupDefault;
    int frames = kFramesDefault;
    int repetition = 0;
};

std::uint64_t hash_u64(std::uint64_t hash, std::uint64_t value) {
    for (unsigned shift = 0; shift < 64; shift += 8) {
        hash ^= (value >> shift) & 0xffU;
        hash *= kFnvPrime;
    }
    return hash;
}

bool parse_integer(const char* value, int* output) {
    char* end = nullptr;
    const long parsed = std::strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed < 0 || parsed > 100000000) return false;
    *output = static_cast<int>(parsed);
    return true;
}

bool parse_options(int argc, char** argv, Options* options) {
    for (int index = 1; index < argc; ++index) {
        const char* argument = argv[index];
        if (std::strncmp(argument, "--workload=", 11) == 0) {
            options->workload = argument + 11;
        } else if (std::strncmp(argument, "--scale=", 8) == 0) {
            if (!parse_integer(argument + 8, &options->scale)) return false;
        } else if (std::strncmp(argument, "--warmup=", 9) == 0) {
            if (!parse_integer(argument + 9, &options->warmup)) return false;
        } else if (std::strncmp(argument, "--frames=", 9) == 0) {
            if (!parse_integer(argument + 9, &options->frames)) return false;
        } else if (std::strncmp(argument, "--repetition=", 13) == 0) {
            if (!parse_integer(argument + 13, &options->repetition)) return false;
        } else {
            return false;
        }
    }
    return options->scale > 0 && options->frames > 0;
}

std::string label_for(int index, bool unique) {
    return unique ? "Widget " + std::to_string(index) : "Widget";
}

int run_labels(int count, bool unique) {
    for (int index = 0; index < count; ++index) {
        const std::string label = label_for(index, unique);
        ImGui::SetCursorPos(ImVec2(static_cast<float>(index % 10) * 126.0f,
                                  static_cast<float>(index / 10) * 18.0f));
        ImGui::TextUnformatted(label.c_str());
    }
    return count;
}

int run_buttons(int count) {
    for (int index = 0; index < count; ++index) {
        ImGui::PushID(index);
        ImGui::SetCursorPos(ImVec2(static_cast<float>(index % 10) * 100.0f,
                                  static_cast<float>(index / 10) * 26.0f));
        ImGui::Button("Button", ImVec2(96.0f, 24.0f));
        ImGui::PopID();
    }
    return count;
}

int run_mixed(int groups, std::vector<bool>* checked, std::vector<float>* values) {
    for (int index = 0; index < groups; ++index) {
        ImGui::PushID(index);
        const float y = static_cast<float>(index) * 30.0f;
        ImGui::SetCursorPos(ImVec2(0.0f, y)); ImGui::TextUnformatted("Label");
        bool value = (*checked)[index];
        ImGui::SetCursorPos(ImVec2(105.0f, y)); ImGui::Checkbox("Check", &value);
        (*checked)[index] = value;
        ImGui::SetCursorPos(ImVec2(230.0f, y)); ImGui::SetNextItemWidth(140.0f);
        ImGui::SliderFloat("Value", &(*values)[index], 0.0f, 1.0f);
        char text[16] = "Input";
        ImGui::SetCursorPos(ImVec2(375.0f, y)); ImGui::SetNextItemWidth(160.0f);
        ImGui::InputText("Input", text, sizeof(text));
        ImGui::SetCursorPos(ImVec2(540.0f, y)); ImGui::Button("Submit", ImVec2(96.0f, 24.0f));
        ImGui::PopID();
    }
    return groups * 5;
}

int run_virtual(int logical_count) {
    const int submitted = std::min(logical_count, kVirtualRows + kVirtualOverscan * 2);
    const int start = std::max(logical_count / 2 - kVirtualOverscan, 0);
    for (int offset = 0; offset < submitted; ++offset) {
        const std::string label = label_for(start + offset, true);
        ImGui::SetCursorPos(ImVec2(0.0f, static_cast<float>(offset) * 18.0f));
        ImGui::TextUnformatted(label.c_str());
    }
    return submitted;
}

int run_table(int rows, bool unique) {
    for (int row = 0; row < rows; ++row) {
        for (int column = 0; column < 4; ++column) {
            const std::string label = label_for(row * 4 + column, unique);
            ImGui::SetCursorPos(ImVec2(static_cast<float>(column) * 220.0f,
                                      static_cast<float>(row) * 18.0f));
            ImGui::TextUnformatted(label.c_str());
        }
    }
    return rows * 4;
}

int run_workload(const Options& options, int frame_index, std::vector<bool>* checked,
                 std::vector<float>* values) {
    const std::string& id = options.workload;
    if (id == "labels_repeated") return run_labels(options.scale, false);
    if (id == "labels_unique" || id == "list_full") return run_labels(options.scale, true);
    if (id == "button_grid" || id == "accessibility" || id == "capacity") return run_buttons(options.scale);
    if (id == "mixed_form") return run_mixed(options.scale, checked, values);
    if (id == "list_virtual") return run_virtual(options.scale);
    if (id == "table_repeated") return run_table(options.scale, false);
    if (id == "table_unique") return run_table(options.scale, true);
    if (id == "dynamic_churn") {
        ImGui::PushID(frame_index % options.scale);
        const int result = run_labels(options.scale, true);
        ImGui::PopID();
        return result;
    }
    return -1;
}

std::int64_t elapsed_ns(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now() - start).count();
}

void print_array(const std::vector<std::int64_t>& values) {
    for (std::size_t index = 0; index < values.size(); ++index) {
        if (index != 0) std::cout << ',';
        std::cout << values[index];
    }
}
}

int main(int argc, char** argv) {
    Options options;
    if (!parse_options(argc, argv, &options)) return 2;
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.DisplaySize = ImVec2(1280.0f, 720.0f);
    io.DeltaTime = 1.0f / 60.0f;
    io.Fonts->AddFontDefault();
    unsigned char* pixels = nullptr;
    int atlas_width = 0;
    int atlas_height = 0;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &atlas_width, &atlas_height);
    const int state_count = std::max(options.scale, 1);
    std::vector<bool> checked(state_count);
    std::vector<float> values(state_count, 0.5f);
    std::vector<std::int64_t> build_samples(options.frames);
    std::vector<std::int64_t> finalize_samples(options.frames);
    std::uint64_t checksum = kFnvBasis;
    int submitted = 0;
    ImDrawData* draw_data = nullptr;
    for (int frame = -options.warmup; frame < options.frames; ++frame) {
        ImGui::NewFrame();
        ImGui::SetNextWindowPos(ImVec2(0.0f, 0.0f), ImGuiCond_Always);
        ImGui::SetNextWindowSize(ImVec2(1280.0f, 720.0f), ImGuiCond_Always);
        ImGui::Begin("Benchmark", nullptr, ImGuiWindowFlags_NoDecoration |
                                               ImGuiWindowFlags_NoSavedSettings |
                                               ImGuiWindowFlags_NoMove);
        const auto build_started = std::chrono::steady_clock::now();
        submitted = run_workload(options, std::max(frame, 0), &checked, &values);
        const std::int64_t build_ns = elapsed_ns(build_started);
        ImGui::End();
        const auto finalize_started = std::chrono::steady_clock::now();
        ImGui::Render();
        const std::int64_t finalize_ns = elapsed_ns(finalize_started);
        draw_data = ImGui::GetDrawData();
        if (submitted < 0) return 2;
        if (frame >= 0) {
            build_samples[frame] = build_ns;
            finalize_samples[frame] = finalize_ns;
            checksum = hash_u64(checksum, static_cast<std::uint64_t>(submitted));
        }
    }
    const int paint_commands = draw_data == nullptr ? 0 : draw_data->CmdListsCount;
    const int vertices = draw_data == nullptr ? 0 : draw_data->TotalVtxCount;
    const bool valid = draw_data != nullptr;
    std::cout << "{\"schema_version\":1,\"framework\":\"imgui\",\"framework_revision\":\"5d4126876bc10396d4c6511853ff10964414c776\",\"backend\":\"headless\",\"layer\":\"core\",\"workload\":\""
              << options.workload << "\",\"scale\":" << options.scale
              << ",\"repetition\":" << options.repetition << ",\"warmup_frames\":"
              << options.warmup << ",\"measured_frames\":" << options.frames
              << ",\"valid\":" << (valid ? "true" : "false")
              << ",\"invalid_reason\":\"" << (valid ? "" : "missing_draw_data")
              << "\",\"state_checksum\":" << checksum << ",\"samples_ns\":{\"build\":[";
    print_array(build_samples);
    std::cout << "],\"finalize\":[";
    print_array(finalize_samples);
    std::cout << "],\"frame\":[]},\"output\":{\"submitted_widgets\":" << submitted
              << ",\"visible_widgets\":" << std::min(submitted, kVirtualRows)
              << ",\"paint_commands\":" << paint_commands << ",\"text_bytes\":0"
              << ",\"dropped_commands\":0,\"dropped_text_bytes\":0},\"renderer\":{\"vertices\":"
              << vertices << ",\"indices\":" << (draw_data == nullptr ? 0 : draw_data->TotalIdxCount)
              << "},\"environment\":{\"os\":\"runner\",\"arch\":\"runner\",\"cpu\":\"runner\",\"toolchain\":\"c++17\"}}\n";
    ImGui::DestroyContext();
    return 0;
}
