local Harness = dofile("tests/harness.lua")

Harness.loadSuite("tests/manager.lua")
Harness.loadSuite("tests/admin.lua")
Harness.loadSuite("tests/migration.lua")
Harness.loadSuite("tests/compatibility.lua")

Harness.run()
