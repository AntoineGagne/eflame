# usage: ruby stacks_to_html.rb filename exchange_id

filename = ARGV[0]
exchange_id = ARGV[1]
raise "missing filename" if filename.nil?

last_pid = nil
samples = {}

File.open(filename, "r") do |f|
  f.each_line do |line|
    line_split = line.split(";")
    pid = line_split[0]
    if last_pid != pid
      samples[pid] = []
      last_pid = pid
    end
    samples[last_pid] << line_split[1..-1].join(";").chomp()
  end
end

count = 0
keys = []
last_sample = nil

samples.keys.each do |pid|
  keys << [pid, samples[pid].size]
  last_sample = samples[pid][0]
  samples["count_" + pid] = []

  samples[pid].each do |sample|
    count += 1
    if last_sample != sample
      samples["count_" + pid] << "#{last_sample} #{count}"
      last_sample = sample
      count = 1
    end
  end
end

graphs = []
path = File.dirname(__FILE__)

keys.sort {|a, b| b[1] <=> a[1]}.each do |pid, count|
  width = 1230 * count / keys[0][1] + 200
  IO.popen(path + "/flamegraph.pl --title='#{pid}' --width=#{width} --hash", 'r+') do |f|
    samples["count_" + pid].each do |sample_count|
      f.puts(sample_count)
    end
    f.close_write
    graphs << "<h4>PID: #{pid} (#{count} samples)</h4>\n" + f.read
  end
end

puts <<-eos
<html>
<head>
<title>RTB Exchange Flame</title>
</head>
<body>
<h2>Exchange Flame</h2>
<h3>Exchange ID: #{exchange_id}</h3>
#{graphs.join("<br /><br />")}
</body>
</html>
eos
