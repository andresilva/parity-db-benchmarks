#!/usr/bin/env ruby

require 'timeout'

$PIDS = []
LINUX = false

def repeat(cmd, interval)
  spawn("while :; do sleep #{interval} & #{cmd}; wait; done;", :out => "/dev/null", :err => "/dev/null")
  # spawn("watch -n #{interval} -p -t '#{cmd}'", :out => "/dev/null", :err => "/dev/null")
end

def benchmark_import(test_case, db_cache_size)
  db_tc = "#{test_case}/#{db_cache_size}MB"
  spawn("time ./bin/parity-#{test_case} --cache-size-db #{db_cache_size} --db-compaction ssd -d state/#{db_tc} import data/blocks.bin 2> logs/#{db_tc}/parity-import.log")
end

def benchmark_restore(test_case, db_cache_size)
  db_tc = "#{test_case}/#{db_cache_size}MB"
  spawn("time ./bin/parity-#{test_case} --cache-size-db #{db_cache_size} --db-compaction ssd -d state/#{db_tc} restore data/snapshot.bin 2> logs/#{db_tc}/parity-restore.log")
end

def benchmark_sync(test_case, db_cache_size)
  db_tc = "#{test_case}/#{db_cache_size}MB"
  spawn("time ./bin/parity-#{test_case} --cache-size-db #{db_cache_size} --no-warp --db-compaction ssd -d state/#{db_tc} 2> logs/#{db_tc}/parity-sync.log")
end

def benchmark_sync_archive(test_case, db_cache_size)
  db_tc = "#{test_case}/#{db_cache_size}MB"
  spawn("time ./bin/parity-#{test_case} --cache-size-db #{db_cache_size} --no-warp --db-compaction ssd -d state/#{db_tc} --pruning archive 2> logs/#{db_tc}/parity-sync-archive.log")
end

def spawn_sudo(cmd)
  spawn("sudo #{cmd}")
  cmd.split.first
end

def iotop(test_case, task, pid)
  if LINUX
    spawn_sudo("iotop -k -b -o -d 5 -p #{pid} > logs/#{test_case}/iotop-#{task}")
  else
    spawn_sudo("iotop -C -t 1 5 > logs/#{test_case}/iotop-#{task} 2> /dev/null") #macOS
  end
end

def ps(test_case, task, pid)
  repeat("ps -a -k -%cpu -p #{pid} -o %cpu,%mem | head -n 2 >> logs/#{test_case}/ps-#{task}", 1)
end

def du(test_case, task)
  repeat("du -ks state/#{test_case}/chains/ethereum/db >> logs/#{test_case}/du-#{task}", 5)
end

def setup(test_case)
  `mkdir -p logs/#{test_case}`
  `mkdir -p state/#{test_case}`
end

def clean_up(test_case)
  `rm -rf state/#{test_case}/*`
  `echo 3 | sudo tee /proc/sys/vm/drop_caches` if LINUX
end

def kill(pid)
  if pid.is_a? String
    `sudo killall #{pid}`
  else
    Process.kill(:SIGTERM, pid)
  end
end

def shutdown
  $PIDS.each(&method(:kill))
end

def wait(wait_pid, pids)
  $PIDS.push(wait_pid)
  $PIDS.concat(pids)

  timeout = 4 * 60 * 60

  begin
    Timeout.timeout(timeout) do
      Process.wait(wait_pid)
    end
  rescue Timeout::Error
    kill(wait_pid)
  ensure
    pids.each(&method(:kill))
  end

  $PIDS.delete(wait_pid)
  pids.each(&$PIDS.method(:delete))
end

def benchmark(test_case, task)
  db_cache_sizes = [
    128,
    256,
    512,
    1024
  ]

  db_cache_sizes.each do |db_cache_size|
    db_cache_size_test_case = "#{test_case}/#{db_cache_size}MB"

    setup(db_cache_size_test_case)
    clean_up(db_cache_size_test_case)

    benchmark_pid =
      if task == 'restore'
        benchmark_restore(test_case, db_cache_size)
      elsif task == 'import'
        benchmark_import(test_case, db_cache_size)
      elsif task == 'sync'
        benchmark_sync(test_case, db_cache_size)
      elsif task == 'sync-archive'
        benchmark_sync_archive(test_case, db_cache_size)
      end

    iotop_pid = iotop(db_cache_size_test_case, task, benchmark_pid)
    ps_pid = ps(db_cache_size_test_case, task, benchmark_pid)
    du_pid = du(db_cache_size_test_case, task)

    pids = [iotop_pid, ps_pid, du_pid]
    wait(benchmark_pid, pids)
  end
end

def benchmarks(test_case)
  benchmark(test_case, 'restore')
  benchmark(test_case, 'import')
  # benchmark(test_case, 'sync')
  # benchmark(test_case, 'sync-archive')
end

Signal.trap("INT") { shutdown; exit }
Signal.trap("TERM") { shutdown; exit }

BENCHMARKS = [
  'rocksdb5-tuning2',
  'rocksdb5-tuning',
  'rocksdb5',
  'default'
]

BENCHMARKS.each do |test_case|
  puts "Running #{test_case} test case."
  benchmarks(test_case)
end
