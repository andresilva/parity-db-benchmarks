require 'erb'
require 'rserve'

LINUX = true

def timeseries(len, interval)
  (0..len * interval).step(interval).to_a.take(len)
end

def parse_ps(file)
  # pairs cpu, mem
  output = `cat #{file} | grep -v CPU | awk '{ print $1, $2 }'`
  output = output.split("\n").map { |s| s.split }
  print output
  [
    ["time", timeseries(output.size, 1)],
    ["CPU", output.map { |n| n[0].to_f }],
    ["MEM", output.map { |n| n[1].to_f }]
  ]
end

def parse_du(file)
  output = `cat #{file} | awk '{ print $1 }'`.split
  [
    ["time", timeseries(output.size, 5)],
    ["size", output.map { |s| s.to_f / 1024 }]
  ]
end

def parse_iotop(file)
  # pairs read, write
  output =
    if LINUX
      `cat #{file} | grep Actual | awk '{ print $4, $10 }'`
    else
      `cat #{file} | grep disk_r | awk '{ print $8, $11 }'`
    end
  output = output.split("\n").map { |s| s.split }
  [
    ["time", timeseries(output.size, 5)],
    ["read", output.map { |n| n[0].to_f / 1024 }],
    ["write", output.map { |n| n[1].to_f / 1024 }]
  ]
end

_rserve = nil
def r_eval(cmd)
  # print cmd

  _rserve ||= Rserve::Connection.new
  rserve = _rserve
  rserve.eval("setwd('#{`pwd`.strip}')")
  palette = %Q{
library(reshape2)
library(ggplot2)
library(ggpubr)
}
  rserve.eval(palette)
  rserve.eval(cmd)
end

def data_frame(name, data)
  data = data.map do |arg|
    n = arg[0]
    vs = arg[1].join(",")
    "#{n} = c(#{vs})"
  end.join(",")

  "#{name} = data.frame(#{data})"
end

def plot_single(name, title, unit, data)
  frame = data_frame("frame", data)
  names = data.map { |x| x[0] }
  input = %Q{
#{frame}
#{name} <- ggplot(data=frame, aes(x=#{names[0]}, y=#{names[1]})) +
geom_area(size=0.75, fill="coral2") +
scale_x_continuous(name="#{names[0].capitalize}", pretty(frame$#{names[0]}, n=10)) +
scale_y_continuous(name="#{unit}", pretty(frame$#{names[1]}, n=10)) +
labs(title="#{title}")
}
end

def plot_double(name, title, unit, data, scale)
  frame = data_frame("frame", data)
  names = data.map { |x| x[0] }
  input = %Q{
#{frame}
frame_melt <- melt(frame, id="#{names[0]}")
#{name} <- ggplot(data=frame_melt, aes(x=#{names[0]}, y=value, colour=variable)) +
  geom_line(size=0.75) +
  scale_x_continuous(name="#{names[0].capitalize}", pretty(frame$#{names[0]}, n=#{scale})) +
  scale_y_continuous(name="#{unit}", pretty(frame_melt$value, n=10)) +
  labs(title="#{title}")
}
end

def plot_save(data, file)
  input = %Q{
#{data}
ggarrange(iotop,
  ggarrange(du, ps, ncol = 2),
  nrow = 2)
ggsave('#{file}.png')
}
  print input
  r_eval(input)
end

class ERBContext
  def initialize(hash)
    hash.each_pair do |key, value|
      instance_variable_set('@' + key.to_s, value)
    end
  end

  def get_binding
    binding
  end
end

def plot_html(test_cases)
  TESTS.each do |test|
    DB_CACHE_SIZES.each do |db_cache_size|
      test_cases.each do |test_case|
        plot = "plots/#{test_case}-#{db_cache_size}MB-#{test}"
      end
    end
  end

  context = ERBContext.new(
    {
      'tests' => TESTS,
      'db_cache_sizes' => DB_CACHE_SIZES,
      'test_cases' => test_cases
    })

  template = ERB.new(File.open('plots.html.erb').read)

  File.write('plots.html', template.result(context.get_binding))
end

def plot_test_case(test_case)
  TESTS.each do |test|
    DB_CACHE_SIZES.each do |db_cache_size|
      db_cache_size_test_case = "#{test_case}/#{db_cache_size}MB"

      plot =
	plot_single("du", "DB Size", "MB", parse_du("logs/#{db_cache_size_test_case}/du-#{test}")) +
	plot_double("iotop", "IO", "MB/s", parse_iotop("logs/#{db_cache_size_test_case}/iotop-#{test}"), 15) +
	plot_double("ps", "CPU/MEM", "%", parse_ps("logs/#{db_cache_size_test_case}/ps-#{test}"), 5)

      plot_save(plot, "plots/#{test_case}-#{db_cache_size}MB-#{test}")
    end
  end
end

DB_CACHE_SIZES = [
  128,
  256,
  512,
  1024
]

TESTS = ['restore', 'import']

BENCHMARKS = [
  'rocksdb5-tuning2',
  'rocksdb5-tuning',
  'rocksdb5',
  'default'
]

BENCHMARKS.each do |test_case|
  puts "Generating plots for test case #{test_case}."
  plot_test_case(test_case)
end

plot_html(BENCHMARKS)
