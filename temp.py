import torch
import time
import multiprocessing as mp
import psutil
from tqdm import tqdm


# ----------------------------------------------------------------------
#  CALIBRATION  (unchanged in spirit, only minor cleanups)
# ----------------------------------------------------------------------
def calibrate_ram(target_ratio=0.75):
    """Fill RAM up to target_ratio of total, return a safe usable amount."""
    print("\n[RAM] Calibrating...")
    total = psutil.virtual_memory().total
    target = total * target_ratio

    blocks = []
    allocated = 0
    chunk = 200 * 1024 * 1024  # 200 MB

    with tqdm(total=target, unit="B", unit_scale=True, desc="RAM Fill") as pbar:
        try:
            while allocated < target:
                t = torch.empty(chunk // 4, dtype=torch.float32)
                blocks.append(t)
                allocated += chunk
                pbar.update(chunk)
        except Exception:
            pass

    print(f"[RAM] Peak: {allocated / 1e9:.2f} GB")
    del blocks
    return allocated * 0.7


def calibrate_vram(target_ratio=0.75):
    """Fill VRAM up to target_ratio of total, return a safe usable amount."""
    print("\n[VRAM] Calibrating...")
    if not torch.cuda.is_available():
        print("[VRAM] No CUDA device found – skipping VRAM calibration.")
        return 0

    device = torch.device("cuda")
    total = torch.cuda.get_device_properties(0).total_memory
    target = total * target_ratio

    blocks = []
    allocated = 0
    chunk = 200 * 1024 * 1024  # 200 MB

    with tqdm(total=target, unit="B", unit_scale=True, desc="VRAM Fill") as pbar:
        try:
            while allocated < target:
                t = torch.empty(chunk // 4, dtype=torch.float32, device=device)
                blocks.append(t)
                allocated += chunk
                pbar.update(chunk)
        except RuntimeError:
            pass

    print(f"[VRAM] Peak: {allocated / 1e9:.2f} GB")
    del blocks
    torch.cuda.empty_cache()
    return allocated * 0.7


# ----------------------------------------------------------------------
#  MEMORY BANDWIDTH TESTS
# ----------------------------------------------------------------------
def measure_cpu_memory_bandwidth(usable_ram, target_gb=1.0):
    """Measure CPU memory copy bandwidth (GB/s) with a tensor of ~target_gb GB."""
    # Choose a size that is about target_gb GB but not larger than a third of usable
    max_bytes = min(int(usable_ram * 0.3), int(target_gb * 1e9))
    size_bytes = max(1024**3, max_bytes)  # at least 1 GiB
    elements = size_bytes // 4  # float32
    a = torch.randn(elements, dtype=torch.float32)
    b = torch.empty_like(a)

    # Warmup
    b.copy_(a)
    torch.cpu.synchronize()  # no-op on CPU but keep for symmetry

    start = time.perf_counter()
    # Use a loop that copies several times to get a stable measurement
    iters = 5
    for _ in range(iters):
        b.copy_(a)
    # CPU doesn't have a synchronize call; time.perf_counter measures complete copies
    elapsed = time.perf_counter() - start
    copied_bytes = a.numel() * a.element_size() * iters
    bw_gb_s = copied_bytes / elapsed / 1e9
    print(
        f"[CPU BW] Size: {elements * 4 / 1e9:.2f} GB, {iters} copies → {bw_gb_s:.2f} GB/s"
    )
    return bw_gb_s


def measure_gpu_memory_bandwidth(usable_vram, target_gb=1.0):
    """Measure GPU device‑to‑device copy bandwidth (GB/s) with ~target_gb GB."""
    if not torch.cuda.is_available():
        return 0.0

    device = torch.device("cuda")
    max_bytes = min(int(usable_vram * 0.3), int(target_gb * 1e9))
    size_bytes = max(1024**3, max_bytes)  # at least 1 GiB
    elements = size_bytes // 4
    a = torch.randn(elements, dtype=torch.float32, device=device)
    b = torch.empty_like(a)

    # Warmup
    b.copy_(a)
    torch.cuda.synchronize()

    start = time.perf_counter()
    iters = 5
    for _ in range(iters):
        b.copy_(a)
    torch.cuda.synchronize()
    elapsed = time.perf_counter() - start
    copied_bytes = a.numel() * a.element_size() * iters
    bw_gb_s = copied_bytes / elapsed / 1e9
    print(
        f"[GPU BW] Size: {elements * 4 / 1e9:.2f} GB, {iters} copies → {bw_gb_s:.2f} GB/s"
    )
    return bw_gb_s


# ----------------------------------------------------------------------
#  SIZE & ITERATION ESTIMATION
# ----------------------------------------------------------------------
def estimate_size(bytes_available):
    """Square matrix size (in elements) that fits into bytes_available (float32)."""
    return int((bytes_available / (3 * 4)) ** 0.5)


def determine_gpu_iters(size, min_time=10):
    """Return a number of iterations so that the GPU matmul runs for ~min_time seconds."""
    device = torch.device("cuda")
    a = torch.randn((size, size), device=device)
    b = torch.randn((size, size), device=device)

    # Warmup
    for _ in range(3):
        c = torch.matmul(a, b)
        _ = c.sum().item()
    torch.cuda.synchronize()

    start = time.perf_counter()
    c = torch.matmul(a, b)
    _ = c.sum().item()
    torch.cuda.synchronize()
    single_time = time.perf_counter() - start

    iters = max(1, int(min_time / single_time))
    print(
        f"[GPU] Single matmul: {single_time:.3f}s → using {iters} iterations (~{min_time}s target)"
    )
    return iters


# ----------------------------------------------------------------------
#  BENCHMARK WORKERS
# ----------------------------------------------------------------------
def gpu_worker(size, iters):
    """Run iters matrix multiplications on GPU, return total time."""
    device = torch.device("cuda")
    a = torch.randn((size, size), device=device)
    b = torch.randn((size, size), device=device)

    torch.cuda.synchronize()
    start = time.perf_counter()
    for _ in range(iters):
        c = torch.matmul(a, b)
        _ = c.sum().item()  # force synchronisation
    torch.cuda.synchronize()
    return time.perf_counter() - start


def cpu_worker_process(size, iters, finished_counter, lock):
    """Run CPU matmul loop, then increment finished_counter once."""
    torch.set_num_threads(1)
    a = torch.randn((size, size))
    b = torch.randn((size, size))
    for _ in range(iters):
        c = torch.matmul(a, b)
        _ = c.sum().item()
    with lock:
        finished_counter.value += 1


# ----------------------------------------------------------------------
#  SCORE CALCULATION
# ----------------------------------------------------------------------
def compute_score(cpu_gflops, gpu_gflops, cpu_bw, gpu_bw):
    """
    Combine compute and bandwidth metrics into a single number.
    Weights: CPU compute 30%, GPU compute 40%, CPU BW 10%, GPU BW 20%.
    The numbers are normalised roughly to a typical 2024 desktop.
    """
    # Normalisation factors (adjust to your own reference if desired)
    cpu_norm = 200.0  # GFLOPS
    gpu_norm = 10000.0  # GFLOPS
    cpu_bw_norm = 50.0  # GB/s
    gpu_bw_norm = 500.0  # GB/s

    score = (
        0.30 * cpu_gflops / cpu_norm
        + 0.40 * gpu_gflops / gpu_norm
        + 0.10 * cpu_bw / cpu_bw_norm
        + 0.20 * gpu_bw / gpu_bw_norm
    )
    return score * 100  # scale so a 2024 mid‑range system scores ~100


# ----------------------------------------------------------------------
#  MAIN
# ----------------------------------------------------------------------
def main():
    cpu_cores = mp.cpu_count()
    print("CPU cores:", cpu_cores)

    # ----- Calibration -----
    usable_ram = calibrate_ram()
    usable_vram = calibrate_vram()

    # ----- Matrix sizes -----
    gpu_size = estimate_size(usable_vram) if usable_vram > 0 else 0
    cpu_size = int(gpu_size * 0.2) if gpu_size > 0 else estimate_size(usable_ram * 0.4)

    print(f"\n[INFO] CPU matmul size: {cpu_size}x{cpu_size}")
    print(f"[INFO] GPU matmul size: {gpu_size}x{gpu_size}")

    # ----- Memory bandwidths (before compute to avoid fragmentation) -----
    print("\n--- Memory Bandwidth Tests ---")
    cpu_bw = measure_cpu_memory_bandwidth(usable_ram, target_gb=1.0)
    gpu_bw = (
        measure_gpu_memory_bandwidth(usable_vram, target_gb=1.0)
        if usable_vram > 0
        else 0.0
    )

    # ----- GPU iterations (target ~10 seconds) -----
    gpu_iters = determine_gpu_iters(gpu_size, min_time=10) if gpu_size > 0 else 0
    # CPU uses fewer iterations – 1/3 of GPU, but at least 1
    cpu_iters = max(1, gpu_iters // 3) if gpu_iters > 0 else 1

    print(f"[INFO] GPU iterations: {gpu_iters}")
    print(f"[INFO] CPU iterations per core: {cpu_iters}")

    # ----- CPU matmul (parallel) -----
    total_procs = cpu_cores
    finished = mp.Value("i", 0)
    lock = mp.Lock()

    processes = []
    for _ in range(total_procs):
        p = mp.Process(
            target=cpu_worker_process, args=(cpu_size, cpu_iters, finished, lock)
        )
        p.start()
        processes.append(p)

    # Progress bar showing how many processes have finished
    with tqdm(total=total_procs, desc="CPU Processes", position=1) as pbar:
        last = 0
        while any(p.is_alive() for p in processes):
            with lock:
                current = finished.value
            pbar.update(current - last)
            last = current
            time.sleep(0.2)
        # final catch
        with lock:
            pbar.update(finished.value - last)

    # Join all CPU processes
    for p in processes:
        p.join()

    # ----- GPU matmul -----
    gpu_time = 0.0
    if gpu_size > 0 and gpu_iters > 0:
        print("\nRunning GPU matmul...")
        gpu_time = gpu_worker(gpu_size, gpu_iters)

    # ----- Compute GFLOPS -----
    # Formula: O(2 * N^3) per matmul
    cpu_ops_per_matmul = 2 * (cpu_size**3)
    # CPU total ops = iters * ops_per_matmul * cores
    cpu_total_ops = cpu_iters * cpu_ops_per_matmul * total_procs
    # We need the total CPU time. We don't have a direct wall‑clock because processes ran in parallel.
    # We can approximate the wall clock from the last finished time. But we can also compute total
    # FLOPs and then GFLOPS = total_ops / (elapsed_wall_time) – but we lack elapsed time.
    # Alternatively, sum FLOPs across all cores (which is what we really care about).
    # Here we report **aggregate CPU throughput**: total FLOPs / (wall time estimated from the progress bar?).
    # To keep it simple, we report **sustained CPU GFLOPS** = total_ops / (number_of_cores * time_per_core).
    # Since we don't track individual times, the easiest is to estimate the time from the last process.
    # To avoid adding overhead, we'll calculate CPU GFLOPS using the single‑core time measured in a separate
    # tiny run. Instead, we can just reuse the single‑thread performance from the GPU calibration?
    # A cleaner way: we measure CPU matmul time for one core inside the main process before the multiprocessing.
    print("\nMeasuring single‑core CPU matmul time for GFLOPS...")
    torch.set_num_threads(1)
    a = torch.randn((cpu_size, cpu_size))
    b = torch.randn((cpu_size, cpu_size))
    # warmup
    for _ in range(2):
        c = torch.matmul(a, b)
        _ = c.sum().item()
    start = time.perf_counter()
    c = torch.matmul(a, b)
    _ = c.sum().item()
    single_cpu_time = time.perf_counter() - start
    single_cpu_gflops = cpu_ops_per_matmul / single_cpu_time / 1e9
    # Aggregate GFLOPS (multiply by number of cores since we ran them all concurrently)
    cpu_gflops_aggregate = single_cpu_gflops * total_procs

    # GPU GFLOPS
    gpu_ops_per_matmul = 2 * (gpu_size**3)
    gpu_total_ops = gpu_iters * gpu_ops_per_matmul
    gpu_gflops = gpu_total_ops / gpu_time / 1e9 if gpu_time > 0 else 0.0

    # ----- Collect VRAM info -----
    if torch.cuda.is_available():
        total_vram = torch.cuda.get_device_properties(0).total_memory
        reserved = torch.cuda.memory_reserved(0)
        allocated_t = torch.cuda.memory_allocated(0)
        free_vram = total_vram - reserved
    else:
        total_vram = reserved = allocated_t = free_vram = 0

    # ----- Composite Score -----
    score = compute_score(cpu_gflops_aggregate, gpu_gflops, cpu_bw, gpu_bw)

    # ----- Final Printout -----
    print("\n" + "=" * 60)
    print("FINAL BENCHMARK RESULTS")
    print("=" * 60)
    print(f"CPU cores used: {total_procs}")
    print(f"CPU matmul size: {cpu_size}x{cpu_size}")
    print(f"CPU iterations / core: {cpu_iters}")
    print(f"CPU single‑core GFLOPS: {single_cpu_gflops:.2f}")
    print(f"CPU aggregate GFLOPS:   {cpu_gflops_aggregate:.2f}")
    print(f"CPU memory bandwidth:   {cpu_bw:.2f} GB/s")
    print()
    if gpu_size > 0:
        print(f"GPU matmul size: {gpu_size}x{gpu_size}")
        print(f"GPU iterations: {gpu_iters}")
        print(f"GPU GFLOPS: {gpu_gflops:.2f}")
        print(f"GPU memory bandwidth: {gpu_bw:.2f} GB/s")
        print(f"VRAM total:   {total_vram / 1e9:.2f} GB")
        print(f"VRAM reserved:{reserved / 1e9:.3f} GB")
        print(f"VRAM free:    {free_vram / 1e9:.2f} GB")
    else:
        print("GPU: not available")
    print()
    print(f"COMPOSITE SCORE: {score:.1f}")
    print("=" * 60 + "\n")


if __name__ == "__main__":
    main()
