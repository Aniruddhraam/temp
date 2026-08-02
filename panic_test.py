import asyncio
import aiohttp
import time
import sys

TARGET_IP = "127.0.0.1"
PORT = "3001"
BASE_URL = f"http://{TARGET_IP}:{PORT}/api"

stats = {
    "total_requests": 0,
    "errors": 0,
    "auth_failures": 0,
    "response_times": [],
    "status_codes": {}
}

stop_event = asyncio.Event()
active_workers = 0

def record_status(status):
    if status not in stats["status_codes"]:
        stats["status_codes"][status] = 0
    stats["status_codes"][status] += 1

async def worker(session, endpoint, headers):
    global active_workers
    active_workers += 1
    
    # Run continuously until failure threshold tells us to stop
    while not stop_event.is_set():
        start_t = time.perf_counter()
        try:
            async with session.get(f"{BASE_URL}{endpoint}", headers=headers) as res:
                stats["response_times"].append(time.perf_counter() - start_t)
                record_status(res.status)
                stats["total_requests"] += 1
                if res.status != 200:
                    stats["errors"] += 1
        except Exception:
            stats["errors"] += 1
            stats["total_requests"] += 1
            
        # tiny sleep to prevent pure CPU lockup
        await asyncio.sleep(0.01)
        
    active_workers -= 1

async def live_display():
    print("\n" * 15)
    start_time = time.time()
    
    while not stop_event.is_set():
        elapsed = time.time() - start_time
        
        times = stats["response_times"][-5000:] # Window of last 5000 requests
        avg_rt = (sum(times) / len(times)) * 1000 if times else 0
        p95_rt = (sorted(times)[int(len(times) * 0.95)] * 1000) if len(times) > 0 else 0
        rps = stats["total_requests"] / elapsed if elapsed > 0 else 0
        
        status_str = " | ".join([f"{k}: {v}" for k, v in sorted(stats["status_codes"].items())])
        if not status_str: status_str = "Waiting for data..."
        
        sys.stdout.write("\033[16A\033[J") 
        sys.stdout.write(f"🚨 UNLIMITED RAMP-UP PANIC SIMULATION 🚨\n")
        sys.stdout.write(f"Elapsed Time: {elapsed:.1f}s\n\n")
        sys.stdout.write(f"👥 Active Concurrent Workers: {active_workers}\n")
        sys.stdout.write(f"🚀 Total DB Requests Sent:    {stats['total_requests']}\n")
        sys.stdout.write(f"📈 Current Throughput:        {rps:.1f} req/sec\n\n")
        
        sys.stdout.write(f"⏱️  Recent Avg Latency: {avg_rt:.0f}ms | p95 Latency: {p95_rt:.0f}ms\n")
        sys.stdout.write(f"📊 Status Codes: {status_str}\n\n")
        
        sys.stdout.write(f"🛑 Auth Fails (Wrong Creds): {stats['auth_failures']}\n")
        sys.stdout.write(f"❌ Errors/Timeouts:          {stats['errors']}\n\n")
        
        # Stop condition: > 10% error rate after a warmup of 500 requests
        error_rate = stats["errors"] / stats["total_requests"] if stats["total_requests"] > 100 else 0
        if error_rate > 0.10 and stats["total_requests"] > 500:
            sys.stdout.write(f"⚠️ FAILURE THRESHOLD REACHED (>10% error rate). DB OR SERVER BUCKLED. STOPPING... ⚠️\n")
            stop_event.set()
            
        sys.stdout.flush()
        await asyncio.sleep(0.5)

async def main():
    async with aiohttp.ClientSession() as session:
        print("Authenticating Admin...")
        admin_token = None
        async with session.post(f"{BASE_URL}/login", json={"username": "admin", "password": "ProjRepAdmin"}) as res:
            if res.status == 200:
                admin_token = res.cookies.get('token').value
            else:
                print("FAILED TO LOGIN AS ADMIN! Is the backend running?")
                return

        print("Authenticating Test Student...")
        student_token = None
        async with session.post(f"{BASE_URL}/login", json={"username": "test_student", "password": "password123"}) as res:
            if res.status == 200:
                student_token = res.cookies.get('token').value
            else:
                print("FAILED TO LOGIN AS test_student! Make sure the backend generated the user.")
                return

        admin_header = {"Cookie": f"token={admin_token}"}
        student_header = {"Cookie": f"token={student_token}"}

        display_task = asyncio.create_task(live_display())
        
        worker_tasks = []
        
        # RAMP UP LOGIC
        try:
            while not stop_event.is_set():
                # Add 50 new students and 5 new admins EVERY SECOND continuously
                for _ in range(50):
                    worker_tasks.append(asyncio.create_task(worker(session, "/fyp/eligibility", student_header)))
                for _ in range(5):
                    worker_tasks.append(asyncio.create_task(worker(session, "/fyp/report/by-student", admin_header)))
                
                await asyncio.sleep(1)
        except KeyboardInterrupt:
            stop_event.set()
            
        # Allow running tasks to cleanly finish or cancel
        if worker_tasks:
            for t in worker_tasks:
                t.cancel()
        await display_task

if __name__ == "__main__":
    asyncio.run(main())
