# Relay schema test authority

`k3-relay-v1.schema.json` is an unchanged hand-written lane A contract copied
from core commit `2700ecc32c6214c3307638ad9590233cd2d6c627`.
SHA-256: `21fddab76da1718e88dfa7ee3d360578763fcdfa0a160ad38cd224b3b704ae10`.

It is not a generated zone. The drift test pins its bytes and compares concrete
frame keys, required fields, closedness, directions and provider/method/error
enums against the Rust mirror. Stateful and normative rules need separate tests.
Any authority update requires independent review and a documented upstream head.
