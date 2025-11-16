#!/usr/bin/env ruby
# Analyze section header table compression potential in object files
#
# Processes files in parallel and reports compression ratios and potential
# file size savings when section headers are compressed with various headers.
require 'etc'
require 'find'
require 'json'

LLVM_READOBJ = ENV['LLVM_READOBJ'] || 'llvm-readobj'

# Calculate the number of bytes needed to encode a value using CLEB128
def cleb128_size(value)
  return 1 if value < 128
  sig_bits = value.bit_length
  n = (sig_bits + 6) / 7
  [n, 9].min
end

# Calculate compact section header size for a section
def calculate_cshdr_size(shdr)
  # sh_name and sh_offset are always present
  size = 1 + cleb128_size(shdr[:sh_name]) + cleb128_size(shdr[:sh_offset])

  # Check fields with defaults and add their sizes if non-default
  [
    [:sh_type, 1],
    [:sh_flags, 0],
    [:sh_addr, 0],
    [:sh_size, 0],
    [:sh_link, 0],
    [:sh_info, 0],
    [:sh_entsize, 0]
  ].each do |field, default|
    if shdr[field] != default
      size += cleb128_size(shdr[field])
    end
  end
  # sh_addralign (default: 1, encoded as log2)
  size += 1 if shdr[:sh_addralign] > 1

  size
end

# Parse section headers from llvm-readobj JSON output
def parse_section_headers(path)
  output = `#{LLVM_READOBJ} -S --elf-output-style=JSON "#{path}" 2>/dev/null`
  return [] if $?.exitstatus != 0

  begin
    data = JSON.parse(output)
    sections = data[0]['Sections'] || []

    sections.map do |section_wrapper|
      section = section_wrapper['Section']
      {
        sh_name: section['Name']['Value'] || 0,
        sh_type: section['Type']['Value'] || 0,
        sh_flags: section['Flags']['Value'] || 0,
        sh_addr: section['Address'] || 0,
        sh_offset: section['Offset'] || 0,
        sh_size: section['Size'] || 0,
        sh_link: section['Link'] || 0,
        sh_info: section['Info'] || 0,
        sh_addralign: section['AddressAlignment'] || 0,
        sh_entsize: section['EntrySize'] || 0
      }
    end
  rescue JSON::ParserError
    []
  end
end


# Collect all .o files
directory = ARGV[0]
object_files = []
Find.find(directory) { |path| object_files << path if File.file?(path) && path.end_with?('.o') }
if object_files.empty?
  puts "No .o file in #{directory}"
  exit
end

# Process files in parallel chunks
total_sht = total_compressed = total_compressed_xz = total_compressed_with_hdr = total_compressed_with_hdr2 = total_cshdr = total_file = 0
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

      # Calculate cshdr size
      section_headers = parse_section_headers(path)
      cshdr_size = 0
      section_headers.each { |shdr| cshdr_size += calculate_cshdr_size(shdr) }

      { path: path, sht_size: sht_size, compressed: compressed, compressed_xz: compressed_xz, cshdr_size: cshdr_size, file_size: file_size }
    end
  end
end.flat_map(&:value)

# Process results sequentially for aggregation and output
results.each do |result|
  path = result[:path]
  sht_size = result[:sht_size]
  compressed = result[:compressed]
  compressed_xz = result[:compressed_xz]
  cshdr_size = result[:cshdr_size]
  file_size = result[:file_size]

  puts "#{path}: #{sht_size} -> #{compressed} (zstd) / #{compressed_xz} (xz) / #{cshdr_size} (cshdr)"

  total_sht += sht_size
  total_compressed += compressed
  total_compressed_xz += compressed_xz
  total_compressed_with_hdr += compressed + 24
  total_compressed_with_hdr2 += compressed + 64 + 24
  total_cshdr += cshdr_size
  total_file += file_size
end

adjusted_file_size_compressed = total_file - total_sht + total_compressed
adjusted_file_size_compressed_xz = total_file - total_sht + total_compressed_xz
adjusted_file_size_with_hdr = total_file - total_sht + total_compressed_with_hdr
adjusted_file_size_with_hdr2 = total_file - total_sht + total_compressed_with_hdr2
adjusted_file_size_cshdr = total_file - total_sht + total_cshdr

puts "Files: #{results.size}"
puts "Total uncompressed: #{total_sht} bytes (#{(total_sht.to_f/total_file*100).round(1)}%)"
puts "Total compressed (zstd): #{total_compressed} bytes (#{(total_compressed.to_f/adjusted_file_size_compressed*100).round(1)}%)"
puts "Total compressed (xz): #{total_compressed_xz} bytes (#{(total_compressed_xz.to_f/adjusted_file_size_compressed_xz*100).round(1)}%)"
puts "Total (compressed + 24): #{total_compressed_with_hdr} bytes (#{(total_compressed_with_hdr.to_f/adjusted_file_size_with_hdr*100).round(1)}%)"
puts "Total (compressed + 64 + 24): #{total_compressed_with_hdr2} bytes (#{(total_compressed_with_hdr2.to_f/adjusted_file_size_with_hdr2*100).round(1)}%)"
# https://maskray.me/blog/2024-03-31-a-compact-section-header-table-for-elf
puts "Total cshdr: #{total_cshdr} bytes (#{(total_cshdr.to_f/adjusted_file_size_cshdr*100).round(1)}%)"
puts "Total file size: #{total_file} bytes"
