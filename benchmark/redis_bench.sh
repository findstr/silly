#!/bin/bash

# Redis Benchmark Comparison Script
# Usage: ./redis_bench.sh <port> [runs] [connections] [requests]
# Example: ./redis_bench.sh 6389 10 20 100000

PORT=${1:-6389}
RUNS=${2:-10}
CONNECTIONS=${3:-20}
REQUESTS=${4:-100000}
CPU_CORE=${5:-8}

echo "=============================================="
echo "Redis Benchmark Test"
echo "=============================================="
echo "Port: $PORT"
echo "Runs: $RUNS"
echo "Connections: $CONNECTIONS"
echo "Requests per run: $REQUESTS"
echo "CPU Core: $CPU_CORE"
echo "=============================================="
echo ""

# Arrays to store results
declare -a PING_INLINE_QPS
declare -a PING_INLINE_P50
declare -a PING_INLINE_P99
declare -a PING_INLINE_P999
declare -a PING_MBULK_QPS
declare -a PING_MBULK_P50
declare -a PING_MBULK_P99
declare -a PING_MBULK_P999

for i in $(seq 1 $RUNS); do
    echo "Run $i/$RUNS..."

    # Run benchmark and capture output
    OUTPUT=$(taskset -c $CPU_CORE redis-benchmark -t ping -c $CONNECTIONS -n $REQUESTS -p $PORT --csv 2>/dev/null)

    # Parse PING_INLINE
    INLINE_LINE=$(echo "$OUTPUT" | grep "PING_INLINE")
    if [ -n "$INLINE_LINE" ]; then
        # CSV format: "test","rps","avg_latency_ms","min_latency_ms","p50_latency_ms","p95_latency_ms","p99_latency_ms","max_latency_ms"
        INLINE_QPS=$(echo "$INLINE_LINE" | cut -d',' -f2 | tr -d '"')
        INLINE_P50=$(echo "$INLINE_LINE" | cut -d',' -f5 | tr -d '"')
        INLINE_P99=$(echo "$INLINE_LINE" | cut -d',' -f7 | tr -d '"')

        PING_INLINE_QPS+=($INLINE_QPS)
        PING_INLINE_P50+=($INLINE_P50)
        PING_INLINE_P99+=($INLINE_P99)
    fi

    # Parse PING_MBULK
    MBULK_LINE=$(echo "$OUTPUT" | grep "PING_MBULK")
    if [ -n "$MBULK_LINE" ]; then
        MBULK_QPS=$(echo "$MBULK_LINE" | cut -d',' -f2 | tr -d '"')
        MBULK_P50=$(echo "$MBULK_LINE" | cut -d',' -f5 | tr -d '"')
        MBULK_P99=$(echo "$MBULK_LINE" | cut -d',' -f7 | tr -d '"')

        PING_MBULK_QPS+=($MBULK_QPS)
        PING_MBULK_P50+=($MBULK_P50)
        PING_MBULK_P99+=($MBULK_P99)
    fi

    # Small delay between runs
    sleep 0.5
done

# Function to calculate statistics
calc_stats() {
    local arr=("$@")
    local len=${#arr[@]}

    if [ $len -eq 0 ]; then
        echo "N/A N/A N/A"
        return
    fi

    # Sort array
    IFS=$'\n' sorted=($(sort -n <<<"${arr[*]}")); unset IFS

    local min=${sorted[0]}
    local max=${sorted[$((len-1))]}

    # Calculate average
    local sum=0
    for val in "${arr[@]}"; do
        sum=$(echo "$sum + $val" | bc -l)
    done
    local avg=$(echo "scale=2; $sum / $len" | bc -l)

    echo "$min $max $avg"
}

echo ""
echo "=============================================="
echo "Results Summary (Port: $PORT)"
echo "=============================================="
echo ""

# PING_INLINE statistics
echo "PING_INLINE:"
echo "  QPS (requests/second):"
read min max avg <<< $(calc_stats "${PING_INLINE_QPS[@]}")
printf "    Min: %s  Max: %s  Avg: %s\n" "$min" "$max" "$avg"

echo "  P50 Latency (ms):"
read min max avg <<< $(calc_stats "${PING_INLINE_P50[@]}")
printf "    Min: %s  Max: %s  Avg: %s\n" "$min" "$max" "$avg"

echo "  P99 Latency (ms):"
read min max avg <<< $(calc_stats "${PING_INLINE_P99[@]}")
printf "    Min: %s  Max: %s  Avg: %s\n" "$min" "$max" "$avg"

echo ""
echo "PING_MBULK:"
echo "  QPS (requests/second):"
read min max avg <<< $(calc_stats "${PING_MBULK_QPS[@]}")
printf "    Min: %s  Max: %s  Avg: %s\n" "$min" "$max" "$avg"

echo "  P50 Latency (ms):"
read min max avg <<< $(calc_stats "${PING_MBULK_P50[@]}")
printf "    Min: %s  Max: %s  Avg: %s\n" "$min" "$max" "$avg"

echo "  P99 Latency (ms):"
read min max avg <<< $(calc_stats "${PING_MBULK_P99[@]}")
printf "    Min: %s  Max: %s  Avg: %s\n" "$min" "$max" "$avg"

echo ""
echo "=============================================="
echo "Raw data for PING_INLINE QPS: ${PING_INLINE_QPS[*]}"
echo "Raw data for PING_MBULK QPS: ${PING_MBULK_QPS[*]}"
echo "=============================================="
