#!/bin/bash

# 修改版的 speedrun.sh，针对单 GPU 内存优化

# 设置内存优化
export OMP_NUM_THREADS=1
export NANOCHAT_BASE_DIR="$HOME/.cache/nanochat"
export PYTORCH_ALLOC_CONF=expandable_segments:True
mkdir -p $NANOCHAT_BASE_DIR

# 检测 GPU 数量
if command -v nvidia-smi &> /dev/null; then
    NUM_GPUS=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
else
    NUM_GPUS=0
fi

echo "Detected $NUM_GPUS GPU(s)"

# 设置训练命令
if [ "$NUM_GPUS" -gt 1 ]; then
    TORCHRUN_CMD="torchrun --standalone --nproc_per_node=$NUM_GPUS"
    echo "Using distributed training with $NUM_GPUS GPUs"
    BATCH_SIZE_ARGS=""
elif [ "$NUM_GPUS" -eq 1 ]; then
    TORCHRUN_CMD="python"
    echo "Using single GPU training with memory optimization"
    # 针对单 GPU 优化批次大小
    BATCH_SIZE_ARGS="--device_batch_size=8"  # 从默认的 32 减少到 8
else
    TORCHRUN_CMD="python"
    echo "No GPU detected, using CPU (this will be very slow!)"
    BATCH_SIZE_ARGS=""
fi

# 设置 wandb
if [ -z "$WANDB_RUN" ]; then
    WANDB_RUN=dummy
fi

# 激活虚拟环境
source .venv/bin/activate

# 重置报告
python -m nanochat.report reset

# 安装 Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# 构建分词器
uv run maturin develop --release --manifest-path rustbpe/Cargo.toml

# 下载数据集
python -m nanochat.dataset -n 8
python -m nanochat.dataset -n 240 &
DATASET_DOWNLOAD_PID=$!

# 训练分词器
python -m scripts.tok_train --max_chars=2000000000
python -m scripts.tok_eval

# 下载评估包
EVAL_BUNDLE_URL=https://karpathy-public.s3.us-west-2.amazonaws.com/eval_bundle.zip
if [ ! -d "$NANOCHAT_BASE_DIR/eval_bundle" ]; then
    curl -L -o eval_bundle.zip $EVAL_BUNDLE_URL
    unzip -q eval_bundle.zip
    rm eval_bundle.zip
    mv eval_bundle $NANOCHAT_BASE_DIR
fi

echo "Waiting for dataset download to complete..."
wait $DATASET_DOWNLOAD_PID

# 基础模型训练 - 使用内存优化参数
echo "Starting base model training with memory optimization..."
if [ "$NUM_GPUS" -gt 1 ]; then
    $TORCHRUN_CMD -m scripts.base_train -- --depth=20 --run=$WANDB_RUN $BATCH_SIZE_ARGS
else
    $TORCHRUN_CMD -m scripts.base_train --depth=20 --run=$WANDB_RUN $BATCH_SIZE_ARGS
fi

# 评估模型
$TORCHRUN_CMD -m scripts.base_loss
$TORCHRUN_CMD -m scripts.base_eval

# 下载身份对话数据
curl -L -o $NANOCHAT_BASE_DIR/identity_conversations.jsonl https://karpathy-public.s3.us-west-2.amazonaws.com/identity_conversations.jsonl

# 中期训练
if [ "$NUM_GPUS" -gt 1 ]; then
    $TORCHRUN_CMD -m scripts.mid_train -- --run=$WANDB_RUN $BATCH_SIZE_ARGS
    $TORCHRUN_CMD -m scripts.chat_eval -- -i mid
else
    $TORCHRUN_CMD -m scripts.mid_train --run=$WANDB_RUN $BATCH_SIZE_ARGS
    $TORCHRUN_CMD -m scripts.chat_eval -i mid
fi

# 监督微调
if [ "$NUM_GPUS" -gt 1 ]; then
    $TORCHRUN_CMD -m scripts.chat_sft -- --run=$WANDB_RUN $BATCH_SIZE_ARGS
    $TORCHRUN_CMD -m scripts.chat_eval -- -i sft
else
    $TORCHRUN_CMD -m scripts.chat_sft --run=$WANDB_RUN $BATCH_SIZE_ARGS
    $TORCHRUN_CMD -m scripts.chat_eval -i sft
fi

# 生成报告
python -m nanochat.report generate
