#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace plate_font {

constexpr int kGlyphWidth = 24;
constexpr int kGlyphHeight = 24;
constexpr int kGlyphBytesPerRow = (kGlyphWidth + 7) / 8;
constexpr int kGlyphStrideBytes = kGlyphHeight * kGlyphBytesPerRow;

struct GlyphBitmap {
    const char* utf8;
    const uint8_t* bitmap;
};

std::size_t glyph_count();
const GlyphBitmap* glyphs();
int glyph_index(std::string_view utf8);
const GlyphBitmap* find_glyph(std::string_view utf8);

}  // namespace plate_font
