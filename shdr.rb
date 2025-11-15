#!/usr/bin/env ruby
# Analyze section header table compression potential in object files
#
# Processes files in parallel and reports compression ratios and potential
# file size savings when section headers are compressed with various headers.
require 'etc'
require 'find'

# Collect all .o files
directory = ARGV[0]
object_files = []
Find.find(directory) { |path| object_files << path if File.file?(path) && path.end_with?('.o') }
if object_files.empty?
  puts "No .o file in #{directory}"
  exit
end

# Process files in parallel chunks
total_sht = total_compressed = total_compressed_xz = total_compressed_with_hdr = total_compressed_with_hdr2 = total_file = 0
chunk_size = (object_files.length.to_f / Etc.nprocessors).ceil
results = object_files.each_slice(chunk_size).map do |chunk|
  Thread.new do
    chunk.filter_map do |path|
      elf_header = `readelf -h "#{path}" 2>/dev/null`
      next if $?.exitstatus != 0

      sht_start = elf_header.lines.find { |line| line.include?("Start of section headers:") }
                             &.split(':')&.last&.strip&.to_i
      next unless sht_start

      file_size = File.size(path)
      sht_size = file_size - sht_start

      compressed = `dd if="#{path}" bs=1 skip=#{sht_start} count=#{sht_size} status=none | zstd -3 -c 2>/dev/null`.bytesize
      compressed_xz = `dd if="#{path}" bs=1 skip=#{sht_start} count=#{sht_size} status=none | xz -c 2>/dev/null`.bytesize

      { path: path, sht_size: sht_size, compressed: compressed, compressed_xz: compressed_xz, file_size: file_size }
    end
  end
end.flat_map(&:value)

# Process results sequentially for aggregation and output
results.each do |result|
  path = result[:path]
  sht_size = result[:sht_size]
  compressed = result[:compressed]
  compressed_xz = result[:compressed_xz]
  file_size = result[:file_size]

  puts "#{path}: #{sht_size} -> #{compressed} (zstd) / #{compressed_xz} (xz)"

  total_sht += sht_size
  total_compressed += compressed
  total_compressed_xz += compressed_xz
  total_compressed_with_hdr += compressed + 24
  total_compressed_with_hdr2 += compressed + 64 + 24
  total_file += file_size
end

adjusted_file_size_compressed = total_file - total_sht + total_compressed
adjusted_file_size_compressed_xz = total_file - total_sht + total_compressed_xz
adjusted_file_size_with_hdr = total_file - total_sht + total_compressed_with_hdr
adjusted_file_size_with_hdr2 = total_file - total_sht + total_compressed_with_hdr2

puts "Files: #{results.size}"
puts "Total uncompressed: #{total_sht} bytes (#{(total_sht.to_f/total_file*100).round(1)}%)"
puts "Total compressed (zstd): #{total_compressed} bytes (#{(total_compressed.to_f/adjusted_file_size_compressed*100).round(1)}%)"
puts "Total compressed (xz): #{total_compressed_xz} bytes (#{(total_compressed_xz.to_f/adjusted_file_size_compressed_xz*100).round(1)}%)"
puts "Total (compressed + 24): #{total_compressed_with_hdr} bytes (#{(total_compressed_with_hdr.to_f/adjusted_file_size_with_hdr*100).round(1)}%)"
puts "Total (compressed + 64 + 24): #{total_compressed_with_hdr2} bytes (#{(total_compressed_with_hdr2.to_f/adjusted_file_size_with_hdr2*100).round(1)}%)"
puts "Total file size: #{total_file} bytes"
