#pragma once

#include "config.h"

#if USE_ICU

#    include <Columns/ColumnString.h>
#    include <Functions/LowerUpperImpl.h>
#    include <base/scope_guard.h>
#    include <unicode/uchar.h>
#    include <unicode/ucasemap.h>
#    include <unicode/unistr.h>
#    include <unicode/urename.h>
#    include <unicode/utypes.h>
#    include <Common/StringUtils.h>

#    include <algorithm>
#    include <array>
#    include <bitset>
#    include <string>
#    include <string_view>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdisabled-macro-expansion"

namespace DB
{

namespace ErrorCodes
{
extern const int BAD_ARGUMENTS;
extern const int LOGICAL_ERROR;
}

template <char not_case_lower_bound, char not_case_upper_bound, bool upper>
struct LowerUpperUTF8Impl
{
    static void vector(
        const ColumnString::Chars & data,
        const ColumnString::Offsets & offsets,
        ColumnString::Chars & res_data,
        ColumnString::Offsets & res_offsets,
        size_t input_rows_count)
    {
        if (input_rows_count == 0)
            return;

        const size_t size = data.size();
        size_t pos = findFirstNonASCII(data.data(), size);
        if (pos == size)
        {
            LowerUpperImpl<not_case_lower_bound, not_case_upper_bound>::vector(data, offsets, res_data, res_offsets, input_rows_count);
            return;
        }

        res_data.resize(size);
        res_offsets.resize_exact(input_rows_count);

        UErrorCode error_code = U_ZERO_ERROR;
        UCaseMap * case_map = ucasemap_open("", U_FOLD_CASE_DEFAULT, &error_code);
        if (U_FAILURE(error_code))
            throw DB::Exception(ErrorCodes::LOGICAL_ERROR, "Error calling ucasemap_open: {}", u_errorName(error_code));

        SCOPE_EXIT(
        {
            ucasemap_close(case_map);
        });

        const auto & two_byte_table = getTwoByteTable(case_map);

        /// ASCII and table mappings keep the length, so outside the rows ICU maps, input byte `i` goes to
        /// `dst_anchor + i - src_anchor`, where the anchors are the input and output ends of the last such row.
        size_t src_anchor = 0;
        size_t dst_anchor = 0;
        size_t row = 0;

        LowerUpperImpl<not_case_lower_bound, not_case_upper_bound>::vectorRaw(data.data(), data.data() + pos, res_data.data());

        while (pos < size)
        {
            if (data[pos] < 0x80)
            {
                const size_t end = pos + findFirstNonASCII(data.data() + pos, size - pos);
                LowerUpperImpl<not_case_lower_bound, not_case_upper_bound>::vectorRaw(
                    data.data() + pos, data.data() + end, res_data.data() + dst_anchor + pos - src_anchor);
                pos = end;
                continue;
            }

            while (offsets[row] <= pos)
            {
                res_offsets[row] = dst_anchor + offsets[row] - src_anchor;
                ++row;
            }
            const size_t row_end = offsets[row];

            /// A sequence never continues into the next row.
            const UInt8 c = data[pos];
            if (c >= 0xC2 && c <= 0xDF && pos + 1 < row_end && (data[pos + 1] & 0xC0) == 0x80)
            {
                const size_t code_point = static_cast<size_t>(c & 0x1F) << 6 | static_cast<size_t>(data[pos + 1] & 0x3F);
                const UInt16 mapped = two_byte_table.mapped[code_point - 0x80];
                if (mapped != 0)
                {
                    UInt8 * dst = res_data.data() + dst_anchor + pos - src_anchor;
                    dst[0] = static_cast<UInt8>(mapped >> 8);
                    dst[1] = static_cast<UInt8>(mapped);
                    pos += 2;
                    continue;
                }
            }

            /// The output before `resume` is ICU's, so ICU maps only the rest of the row. In the root locale only
            /// final sigma depends on other characters, and it needs the last one its check does not skip.
            const size_t row_start = row == 0 ? 0 : offsets[row - 1];
            size_t resume = pos;
            if constexpr (!upper)
                resume = row_start + findSigmaContextStart(data.data() + row_start, pos - row_start);

            /// ICU APIs accept `int32_t` for buffer sizes and return the required output
            /// length as `int32_t` on `U_BUFFER_OVERFLOW_ERROR`. Unicode full case mapping
            /// (Unicode `SpecialCasing.txt`, e.g. `U+0390` maps to 3 code points / 6 bytes
            /// from a 2-byte input) expands UTF-8 output by at most 3x. Reject inputs
            /// whose worst-case case-mapped output could exceed `INT32_MAX` — the retry
            /// path could otherwise receive an overflowed `dst_size` and corrupt `res_data`.
            const size_t src_size = row_end - row_start;
            if (static_cast<int64_t>(src_size) * 3 > INT32_MAX)
                throw Exception(
                    ErrorCodes::BAD_ARGUMENTS,
                    "String size {} exceeds the maximum supported length for {}: "
                    "case mapping could produce output larger than the 2 GiB ICU API limit",
                    src_size,
                    upper ? "upperUTF8" : "lowerUTF8");

            const size_t dst_pos = dst_anchor + resume - src_anchor;
            dst_anchor = dst_pos + mapWithICU(case_map, data.data() + resume, row_end - resume, res_data, dst_pos);
            src_anchor = row_end;
            res_offsets[row] = dst_anchor;
            ++row;
            pos = row_end;

            if (res_data.size() < dst_anchor + (size - src_anchor))
                res_data.resize(dst_anchor + (size - src_anchor));
        }

        for (; row < input_rows_count; ++row)
            res_offsets[row] = dst_anchor + offsets[row] - src_anchor;

        res_data.resize(dst_anchor + (size - src_anchor));
    }

    static void vectorFixed(const ColumnString::Chars &, size_t, ColumnString::Chars &, size_t)
    {
        throw Exception(ErrorCodes::BAD_ARGUMENTS, "Functions lowerUTF8 and upperUTF8 cannot work with FixedString argument");
    }

private:
    /// Maps `src` with ICU to `res_data` at `dst_pos`, growing `res_data` if the output does not fit. Returns the output size.
    static size_t mapWithICU(const UCaseMap * case_map, const UInt8 * src, size_t src_size, ColumnString::Chars & res_data, size_t dst_pos)
    {
        const auto * src_chars = reinterpret_cast<const char *>(src);
        const auto safe_src_size = static_cast<int32_t>(src_size);

        /// `res_data` accumulates output for all rows and may exceed `INT32_MAX`. Cap
        /// the destination capacity passed to ICU; the `U_BUFFER_OVERFLOW_ERROR` retry
        /// path enlarges `res_data` to fit and the guard in `vector` keeps the per-row
        /// requested length representable as `int32_t`.
        auto safe_dest_capacity = static_cast<int32_t>(std::min<size_t>(res_data.size() - dst_pos, INT32_MAX));

        UErrorCode error_code = U_ZERO_ERROR;
        int32_t dst_size = 0;
        if constexpr (upper)
            dst_size = ucasemap_utf8ToUpper(
                case_map, reinterpret_cast<char *>(&res_data[dst_pos]), safe_dest_capacity, src_chars, safe_src_size, &error_code);
        else
            dst_size = ucasemap_utf8ToLower(
                case_map, reinterpret_cast<char *>(&res_data[dst_pos]), safe_dest_capacity, src_chars, safe_src_size, &error_code);

        if (error_code == U_BUFFER_OVERFLOW_ERROR)
        {
            res_data.resize(dst_pos + dst_size);
            safe_dest_capacity = static_cast<int32_t>(std::min<size_t>(res_data.size() - dst_pos, INT32_MAX));

            error_code = U_ZERO_ERROR;
            if constexpr (upper)
                dst_size = ucasemap_utf8ToUpper(
                    case_map, reinterpret_cast<char *>(&res_data[dst_pos]), safe_dest_capacity, src_chars, safe_src_size, &error_code);
            else
                dst_size = ucasemap_utf8ToLower(
                    case_map, reinterpret_cast<char *>(&res_data[dst_pos]), safe_dest_capacity, src_chars, safe_src_size, &error_code);
        }

        if (error_code != U_ZERO_ERROR && error_code != U_STRING_NOT_TERMINATED_WARNING)
            throw Exception(
                ErrorCodes::LOGICAL_ERROR,
                "Error calling {}: {} input: {} input_size: {}",
                upper ? "ucasemap_utf8ToUpper" : "ucasemap_utf8ToLower",
                u_errorName(error_code),
                std::string_view(src_chars, src_size),
                src_size);

        return static_cast<size_t>(dst_size);
    }

    struct TwoByteTable
    {
        /// (first << 8) | second output byte for each code point U+0080..U+07FF, 0 if a row containing it goes to ICU.
        std::array<UInt16, 0x800 - 0x80> mapped{};
    };

    static const TwoByteTable & getTwoByteTable(const UCaseMap * case_map)
    {
        static const TwoByteTable table = buildTwoByteTable(case_map);
        return table;
    }

    /// The entries are ICU's own mappings. The context probes drop mappings that depend on the neighbouring
    /// characters (Final_Sigma in the root locale).
    static TwoByteTable buildTwoByteTable(const UCaseMap * case_map)
    {
        auto map = [case_map](UInt32 code_point, std::string_view src)
        {
            constexpr int32_t capacity = 32;
            char dst[capacity];
            UErrorCode error_code = U_ZERO_ERROR;
            int32_t dst_size = 0;
            if constexpr (upper)
                dst_size = ucasemap_utf8ToUpper(case_map, dst, capacity, src.data(), static_cast<int32_t>(src.size()), &error_code);
            else
                dst_size = ucasemap_utf8ToLower(case_map, dst, capacity, src.data(), static_cast<int32_t>(src.size()), &error_code);

            if (error_code != U_ZERO_ERROR)
                throw Exception(
                    ErrorCodes::LOGICAL_ERROR,
                    "Error calling {} for code point U+{:04X}: {}",
                    upper ? "ucasemap_utf8ToUpper" : "ucasemap_utf8ToLower",
                    code_point,
                    u_errorName(error_code));

            return std::string(dst, static_cast<size_t>(dst_size));
        };

        const std::string letter = map('A', "A");

        TwoByteTable table{};
        for (UInt32 code_point = 0x80; code_point < 0x800; ++code_point)
        {
            const std::string c{static_cast<char>(0xC0 | (code_point >> 6)), static_cast<char>(0x80 | (code_point & 0x3F))};
            const std::string mapped = map(code_point, c);
            if (mapped.size() == 2
                && map(code_point, "A" + c) == letter + mapped
                && map(code_point, c + "A") == mapped + letter
                && map(code_point, "A" + c + "A") == letter + mapped + letter)
                table.mapped[code_point - 0x80] = static_cast<UInt16>(static_cast<UInt8>(mapped[0]) << 8 | static_cast<UInt8>(mapped[1]));
        }

        return table;
    }

    /// Case_Ignorable code points U+0000..U+07FF, which the final sigma check of ICU skips.
    static const std::bitset<0x800> & getSigmaIgnorable()
    {
        static const std::bitset<0x800> ignorable = []
        {
            std::bitset<0x800> res;
            for (UInt32 code_point = 0; code_point < 0x800; ++code_point)
                res[code_point] = u_hasBinaryProperty(static_cast<UChar32>(code_point), UCHAR_CASE_IGNORABLE);
            return res;
        }();
        return ignorable;
    }

    /// Start of the last character before `pos` that the final sigma check of ICU does not skip, or 0.
    /// The bytes before `pos` are ASCII or two-byte sequences with a table entry.
    static size_t findSigmaContextStart(const UInt8 * src, size_t pos)
    {
        const auto & ignorable = getSigmaIgnorable();
        while (pos > 0)
        {
            pos -= src[pos - 1] < 0x80 ? 1 : 2;
            const size_t code_point = src[pos] < 0x80 ? src[pos] : (static_cast<size_t>(src[pos] & 0x1F) << 6 | (src[pos + 1] & 0x3F));
            if (!ignorable[code_point])
                return pos;
        }
        return 0;
    }
};

}

#pragma clang diagnostic pop

#endif
