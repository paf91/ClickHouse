#pragma once

#include <Core/Block.h>
#include <Core/ColumnNumbers.h>
#include <Core/ColumnWithTypeAndName.h>
#include <Core/ColumnsWithTypeAndName.h>
#include <Core/Names.h>
#include <Core/NamesAndTypes.h>
#include <Processors/Chunk.h>
#include <Processors/ISimpleTransform.h>
#include <Compression/ICompressionCodec.h>
#include <Storages/ColumnSize.h>
#include <Common/CacheBase.h>
#include <Common/UnorderedMapWithMemoryTracking.h>

#include <cstddef>
#include <memory>
#include <mutex>
#include <optional>

namespace DB
{

class Aggregator;
struct AggregatedDataVariants;

struct RuntimeDataflowStatistics
{
    /// The read parallel replicas would coordinate: they split it, so the cost model divides it by their
    /// number.
    size_t input_bytes = 0;
    /// Every other read of the same subtree. Parallel replicas do not split these - each replica runs the
    /// whole subtree, so each reads all of them. They cost the same wall-clock time either way, which is
    /// why they are kept apart from `input_bytes` rather than added to it, but they cost the cluster
    /// `num_replicas` times as much work, which is what the amplification gate weighs.
    size_t replicated_bytes = 0;
    size_t output_bytes = 0;
    size_t total_rows_to_read = 0;
};

inline RuntimeDataflowStatistics operator+(const RuntimeDataflowStatistics & lhs, const RuntimeDataflowStatistics & rhs)
{
    return RuntimeDataflowStatistics{lhs.input_bytes + rhs.input_bytes, lhs.output_bytes + rhs.output_bytes};
}

class RuntimeDataflowStatisticsCache
{
public:
    using Entry = RuntimeDataflowStatistics;
    using Cache = DB::CacheBase<UInt64, Entry>;
    using CachePtr = std::shared_ptr<Cache>;

    RuntimeDataflowStatisticsCache()
        : stats_cache(std::make_shared<Cache>(CurrentMetrics::end(), CurrentMetrics::end(), 1024 * 1024 * 1024, 0))
    {
    }

    std::optional<Entry> getStats(size_t key) const;

    void update(size_t key, RuntimeDataflowStatistics stats);

private:
    CachePtr stats_cache;
};

RuntimeDataflowStatisticsCache & getRuntimeDataflowStatisticsCache();

/// The codecs a column's `CODEC` resolves to, for the two shapes its serialized sample can have.
///
/// The writer resolves a `CODEC` per substream: a type-specific codec (`ALP`, `T64`, `Delta`, ...) is
/// applied only to a substream that carries the column type itself, and structural substreams (`Array`
/// offsets, null map, sparse offsets, ...) keep only the generic codecs. The estimate serializes a whole
/// column into a single buffer, so `type_specific` describes that buffer only when it holds exactly one
/// stream of `type_specific_for`. Neither is a property of the table metadata alone: the serialization is
/// chosen per block from the column at hand, and an unfinished `ALTER MODIFY COLUMN` leaves the part
/// holding the old type while the metadata already reports the new one.
struct ColumnCodecs
{
    /// Null when the column's `CODEC` has no resolution against a type - then only `generic` applies.
    CompressionCodecPtr type_specific = nullptr;
    DataTypePtr type_specific_for = nullptr;
    CompressionCodecPtr generic = nullptr;
};

/// Only columns whose `CODEC` overrides the part's default; resolved once per read task.
using ColumnCodecByName = UnorderedMapWithMemoryTracking<String, ColumnCodecs>;

/// Whether `serialization` writes the column as a single stream carrying `type` itself, the only layout
/// a type-specific codec may be applied to.
bool isSerializedAsSingleStreamOfColumnType(const ISerialization & serialization, const DataTypePtr & type);

/// Accumulates one execution's statistics and writes its single cache entry. It lives in the `.cpp`:
/// nothing outside needs its layout.
class RuntimeDataflowStatisticsCacheUpdaterImpl;

/// A handle a plan step holds on the accumulator of the execution it belongs to. Several steps share one
/// accumulator - the coordinated read, the boundary node whose output is measured, and the read's lazy half
/// all record into the same entry - and each handle carries the role its own input reads play in it. The
/// entry is written once, when the last handle is gone.
class RuntimeDataflowStatisticsCacheUpdater
{
    using ColumnSizeByName = std::unordered_map<std::string, ColumnSize>;

public:
    /// Which bucket this handle's input reads belong to. Parallel replicas split only the coordinated read;
    /// every other read of the subtree is performed by each replica in full.
    enum class InputRole
    {
        Coordinated,
        Replicated,
    };

    /// A handle on a fresh accumulator, for the read parallel replicas would coordinate.
    static std::shared_ptr<RuntimeDataflowStatisticsCacheUpdater> createCoordinated(size_t cache_key, size_t total_rows_to_read);

    /// Another handle on the same accumulator, for the reads parallel replicas would not split. One handle
    /// serves all of them: their bytes accumulate into a single bucket either way.
    static std::shared_ptr<RuntimeDataflowStatisticsCacheUpdater>
    createForReplicatedReads(const std::shared_ptr<RuntimeDataflowStatisticsCacheUpdater> & coordinated);

    void recordOutputChunk(const Chunk & chunk, const Block & header);

    void recordAggregationStateSizes(AggregatedDataVariants & variant, ssize_t bucket);

    void recordAggregationKeySizes(const Chunk & chunk, const ColumnNumbers & keys_positions, const DataTypes & key_types);

    /// For a conversion that materialized only some of the groups (the bucket Top-K):
    /// `full_key_bytes` is the byte size all keys would occupy materialized, measured on the
    /// hash table, and the chunk provides the compression-ratio sample only. The statistics
    /// must describe the untruncated output because they price the parallel-replicas plan,
    /// whose partial aggregation materializes every group.
    void recordAggregationKeySizes(
        const Chunk & chunk, const ColumnNumbers & keys_positions, const DataTypes & key_types, size_t full_key_bytes);

    /// Estimates compressed size of aggregate state columns in the output chunk.
    /// Mirrors the logic of Aggregator::estimateSizeOfCompressedState but works on ColumnAggregateFunction columns
    /// rather than a hash table. Used by in-order aggregation where states are already materialized into columns (single-stream case).
    void recordAggregationStateColumnSizes(const Chunk & chunk, const ColumnNumbers & keys_positions, const Block & header);

    /// Updates should_continue_sampling to true if the current read block is chosen for sampling.
    /// It is needed because in general we read each block in multiple steps because of prewhere.
    /// If the first part of the block was chosen for sampling, we want to record statistics for the whole block in later steps,
    /// so should_continue_sampling remains true for subsequent calls for the same logical block.
    void recordInputColumns(
        const ColumnsWithTypeAndName & input_columns,
        const NameSet & partially_read_columns,
        const NamesAndTypesList & part_columns,
        const ColumnSizeByName & column_sizes,
        const ColumnCodecByName & column_codecs,
        const CompressionCodecPtr & default_codec,
        size_t read_bytes,
        std::optional<bool> & should_continue_sampling);

    void markUnsupportedCase();

private:
    RuntimeDataflowStatisticsCacheUpdater(std::shared_ptr<RuntimeDataflowStatisticsCacheUpdaterImpl> impl_, InputRole role_);

    const std::shared_ptr<RuntimeDataflowStatisticsCacheUpdaterImpl> impl;
    const InputRole role;
};

using RuntimeDataflowStatisticsCacheUpdaterPtr = std::shared_ptr<RuntimeDataflowStatisticsCacheUpdater>;

class RuntimeDataflowStatisticsCollector : public ISimpleTransform
{
public:
    RuntimeDataflowStatisticsCollector(SharedHeader header_, RuntimeDataflowStatisticsCacheUpdaterPtr updater_);

    String getName() const override { return "RuntimeDataflowStatisticsCollector"; }

protected:
    void transform(Chunk & chunk) override;

private:
    RuntimeDataflowStatisticsCacheUpdaterPtr updater;
};
}
