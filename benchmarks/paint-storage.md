# Paint storage baseline

Measured on the current native target with `odin run benchmarks/paint_size.odin
-file -collection:ingot=.`:

| Value | Bytes |
|---|---:|
| `Paint_Command` | 120 |
| One command array | 3,932,160 |
| One text array | 262,144 |
| `Paint_List` | 4,198,064 |
| `Ui_Output` | 8,418,736 |

The widget benchmark smoke matrix passes with fixed-storage growth telemetry at
zero. The representation is large, but changing it would alter every append and
replay path. No tagged-union or SoA rewrite is justified by size alone: the next
step requires before/after CPU, cache, and replay evidence from equivalent
implementations. `ui_paint_storage_stats` keeps these values directly
inspectable so future work can compare rather than estimate them.
