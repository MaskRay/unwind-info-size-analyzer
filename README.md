# Object File Size Analyzer

A collection of tools for analyzing ELF binaries and object files, including section sizes, symbol comparisons, compression potential, and stack unwinding data overhead.

These tools are used in the blog post: [Stack walking: space and time trade-offs](https://maskray.me/blog/2025-10-26-stack-walking-space-and-time-trade-offs)

## Tools

- **`compare_symbols.rb`** - Analyzes and compares function symbols between two executable files, showing size differences for functions above a specified threshold
- **`eh_size.rb`** - Extracts and analyzes section sizes (.eh_frame, .eh_frame_hdr, .sframe) from ELF files using readelf
- **`scan_eh_frame.rb`** - Analyzes .eh_frame section size distribution across system binaries using bloaty to measure VM size ratios
- **`section_size.rb`** - Analyzes executable file sections using readelf to extract and analyze section sizes with formatted output tables
- **`shdr.rb`** - Analyzes section header table compression potential in object files using zstd and xz compression
