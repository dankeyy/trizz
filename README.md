# trizz
A bl*zingly fast `tree` implementation

![image](https://user-images.githubusercontent.com/74069206/232853794-48cb8ee7-2f9a-4969-b923-0be9e1ad3a87.png)

Build with `zig build-exe -OReleaseFast -fstrip trizz.zig` for maximum performance.\
Supports the following optional arguments:
- path
- `--sorted` (unsorted by default)
- `--no-color` (colored by default)
- `-a` to show hidden files (skipped by default)
- `--count` to show file and directory count (uncounted by default)
