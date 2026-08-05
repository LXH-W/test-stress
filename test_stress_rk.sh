#!/bin/bash

# 脚本所在目录
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# 上级目录（脚本目录的父目录）
PARENT_DIR=$(dirname "${SCRIPT_DIR}")


# 加载配置文件
source ${SCRIPT_DIR}/config.conf > /dev/null 2>&1

# 配置文件中参数为空，使用默认参数（小时）
if [[ -z "${set_aging_time}" ]]; then
    set_aging_time=2
fi

# 检查是否为数字（浮点数或整数）
if [[ ! "${set_aging_time}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo -e "\033[31m Error: Aging time setting is incorrect \033[0m"
    exit 1
fi

# 创建文件夹
AGING_BASE_DIR="${SCRIPT_DIR}/stress"
mkdir -p "${AGING_BASE_DIR}"

# 日志文件
log_file="${AGING_BASE_DIR}/log_file.log"
stress_ng="${AGING_BASE_DIR}/stress_ng.log"


# 检查依赖工具
for cmd in stress-ng figlet glmark2-es2 bc; do
    if ! command -v "${cmd}" &> /dev/null; then
        echo -e "\033[31m Error: ${cmd} is not installed \033[0m"
        exit 1
    fi
done


# CPU老化测试
run_cpu_test() {
    # 在 aging_time 基础上增加 3 秒缓冲
    local cpu_duration=$((aging_time + 3))

    # 满负载，自动轮询所有测试方法
    stress-ng --cpu $(nproc) --metrics-brief --timeout ${cpu_duration}s >> ${stress_ng} 2>&1

    sleep 2
}


# 内存老化测试
run_memory_test() {
    local mem_duration=$((aging_time + 3))

    available_memory=$(free -m | grep -E 'Mem|内存' | awk '{print $7}')
    # 使用 80% 左右的内存测试
    test_memory=$((available_memory * 80 / 100))

    # 内存全模式老化测试，占用80%可用内存并锁定物理页防swap
    stress-ng --vm 1 \
    --vm-bytes ${test_memory}M \
    --vm-method all \
    --vm-keep \
    --vm-populate \
    --vm-locked \
    --oom-avoid \
    --oom-avoid-bytes 512M \
    --metrics-brief \
    --timeout ${mem_duration}s \
    >> ${stress_ng} 2>&1

    sleep 2
}


# GPU老化测试
run_gpu_test() {
    local gpu_duration=$((aging_time + 3))

    # 配置文件用户为空, 直接使用当前账号
    if [[ -n "${user}" ]]; then
        user_name="${user}"
    else
        user_name="${USER}"
    fi
    user_id=$(sudo -u ${user_name} id -u)
    su ${user_name} -c "export XDG_RUNTIME_DIR=/run/user/${user_id} && timeout ${gpu_duration} glmark2-es2 --run-forever --annotate > /dev/null 2>&1"

    sleep 2
}


get_system_status(){
    # 1. 获取CPU当前使用率
    cpu_usage_percent=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    
    # 2. 获取CPU当前温度
    cpu_temp_raw=$(cat /sys/devices/virtual/thermal/thermal_zone0/temp 2>/dev/null)
    if [[ -n "${cpu_temp_raw}" ]]; then
        cpu_temp=$(echo "scale=1; ${cpu_temp_raw} / 1000" | bc)
    else
        cpu_temp="---"
    fi
    
    # 3. 获取CPU当前实时频率
    cpu_cur_freq_raw=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_cur_freq 2>/dev/null)
    if [[ -n "${cpu_cur_freq_raw}" ]]; then
        cpu_cur_freq=$(echo "scale=2; ${cpu_cur_freq_raw} / 1000" | bc)
    else
        cpu_cur_freq="---"
    fi
    
    # 4. 获取内存信息
    # 获取总内存、可用内存
    memory_info=$(free -m)
    total_memory=$(echo "${memory_info}" | grep -E 'Mem|内存' | awk '{print $2}')
    available_memory=$(echo "${memory_info}" | grep -E 'Mem|内存' | awk '{print $7}')

    # 计算已使用内存（单位：MB）
    used_memory=$((total_memory - available_memory))

    # 计算使用百分比（保留整数）
    memory_usage_percent=$((used_memory * 100 / total_memory))
    
    # 转换为 GB（保留1位小数）
    used_memory_gb=$(echo "scale=1; ${used_memory} / 1024" | bc)
    total_memory_gb=$(echo "scale=1; ${total_memory} / 1024" | bc)

    # 5.获取GPU当前使用率
    gpu_load_raw=$(cat /sys/devices/platform/*.gpu/devfreq/*.gpu/load 2>/dev/null)
    if [[ -n "${gpu_load_raw}" ]]; then
        gpu_usage_percent="${gpu_load_raw%%@*}"
    else
        gpu_usage_percent="---"
    fi

    # \033[2K 清除当前行，\033[H 光标回到行首
    printf "\033[H"
    printf "\033[2K=============================================\n"
    printf "\033[2K   [Burn-in Test] System Real-Time Monitor\n"
    printf "\033[2K=============================================\n"
    printf "\033[2KUp Time:       $(printf "%02d:%02d:%02d" $1 $2 $3)\n"
    printf "\033[2K=============================================\n"
    printf "\033[2KCPU Usage:     ${cpu_usage_percent} %%\n"
    printf "\033[2KCPU Temp:      ${cpu_temp} °C\n"
    printf "\033[2KCPU Cur Freq:  ${cpu_cur_freq} MHz\n"
    printf "\033[2K=============================================\n"
    printf "\033[2KMemory Usage:  ${memory_usage_percent} %%\n"
    printf "\033[2KUsed/Total:    ${used_memory_gb}/${total_memory_gb} GB\n"
    printf "\033[2K=============================================\n"
    printf "\033[2KGPU Usage:     ${gpu_usage_percent} %%\n"
    printf "\033[2K=============================================\n"
}


check_stress_processes() {
    # 1. 检查 stress-ng-cpu
    if ! pgrep -x "stress-ng-cpu" > /dev/null 2>&1; then
        pkill -TERM -f "stress-ng"
        pkill -TERM -f "glmark2-es2"
        echo -e "\033[31m Error: stress-ng-cpu process abnormal, aging test failed. \033[0m"
        exit 1
    fi

    # 2. 检查 stress-ng-vm
    if ! pgrep -x "stress-ng-vm" > /dev/null 2>&1; then
        pkill -TERM -f "stress-ng"
        pkill -TERM -f "glmark2-es2"
        echo -e "\033[31m Error: stress-ng-vm process abnormal, aging test failed. \033[0m" 
        exit 1
    fi

    # 3. 检查 glmark2-es2
    if ! pgrep -x "glmark2-es2" > /dev/null 2>&1; then
        pkill -TERM -f "stress-ng"
        echo -e "\033[31m Error: glmark2-es2 process abnormal, aging test failed. \033[0m"
        exit 1
    fi
}


cleanup() {
    # 显示光标
    tput cnorm
    # 杀死所有 stress-ng 进程和 glmark2-es2 进程
    sleep 2
    pkill -TERM -f "stress-ng"
    pkill -TERM -f "glmark2-es2"
    sleep 2
    printf "\n"
    exit 0
}


run_test() {
    # 记录开始
    touch ${AGING_BASE_DIR}/start_state.zz
    # 小时转换秒
    aging_time=$(echo "scale=0; ${set_aging_time} * 60 * 60 / 1" | bc)
    # 记录开始测试时间和老化测试时长
    echo "start time: $(date)" >> ${log_file}
    echo "Aging duration: ${aging_time}S" >> ${log_file}

    #运行测试（GPU使用率通过启用多次测试可达到90%以上）
    run_cpu_test &
    run_memory_test &
    run_gpu_test &

    start_time=$(date +%s)

    sleep 2

    # 隐藏光标
    tput civis
    # 捕捉到Ctrl+C信号,执行cleanup函数
    trap cleanup SIGINT
    # 清除屏幕
    clear
    sleep 1

    # 循环直到老化时间结束
    while true; do
        current_time=$(date +%s)  # 获取当前时间
        elapsed_time=$((current_time - start_time))  # 计算已老化时间

        # 将已老化时间转换为小时、分钟和秒
        hours=$((elapsed_time / 3600))
        minutes=$(( (elapsed_time % 3600) / 60 ))
        seconds=$((elapsed_time % 60))

        get_system_status ${hours} ${minutes} ${seconds}

        # 检查是否已经达到老化时间
        if [ "$elapsed_time" -ge "$aging_time" ]; then
            echo "stop time: $(date)" >> ${log_file}
            break
        fi

        check_stress_processes

        # 每隔1秒更新一次显示
        sleep 1
    done

    # 等待所有测试完成
    wait

    # 显示光标
    tput cnorm

    echo "============================================="
    echo -e "\033[32m$(figlet "PASS")\033[0m"
    echo "============================================="

    # 记录结束
    touch ${AGING_BASE_DIR}/end_state.zz

    # 测试通过关机
    shutdown now
}

start_state="${AGING_BASE_DIR}/start_state.zz"
end_state="${AGING_BASE_DIR}/end_state.zz"
if [[ -e "$start_state" ]] && [[ ! -e "$end_state" ]]; then
    echo -e "\033[31m$(figlet "FAIL")\033[0m"
    read -p "Aging test failed, please choose whether to re-execute aging test? (y/n):" answer
    if [ "$answer" = "Y" ] || [ "$answer" == "y" ]; then
        rm -rf ${AGING_BASE_DIR}/*
        run_test
    else
        exit 0
    fi
elif [[ -e "$start_state" ]] && [[ -e "$end_state" ]]; then
    echo -e "\033[32m$(figlet "PASS")\033[0m"
    read -p "The equipment has completed the aging test and passed. Would you like to re-execute the aging test? (y/n):" answer
    if [ "$answer" = "Y" ] || [ "$answer" == "y" ]; then
        rm -rf ${AGING_BASE_DIR}/*
        run_test
    else
        exit 0
    fi
else
    run_test
fi
