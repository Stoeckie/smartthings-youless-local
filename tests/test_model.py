from run_lua import runtime, req


def m():
    return req(runtime(), "youless_model")


def test_from_e_p1_meter():
    lua = runtime()
    model = req(lua, "youless_model")
    e = lua.eval(b'{ { net = 37423.938, pwr = 6492, p1 = 37793.680, p2 = 36692.651, n1 = 10916.630, n2 = 26145.763, gas = 17563.217 } }')
    r = model.from_e(e)
    assert r.power == 6492
    assert abs(r.import_kwh - 74486.331) < 1e-6
    assert abs(r.export_kwh - 37062.393) < 1e-6
    assert abs(r.gas_m3 - 17563.217) < 1e-6


def test_from_e_without_gas():
    lua = runtime()
    model = req(lua, "youless_model")
    r = model.from_e(lua.eval(b'{ { pwr = -510, p1 = 1, p2 = 2, n1 = 3, n2 = 4, gas = 0 } }'))
    assert r.power == -510 and r.gas_m3 is None


def test_from_a_comma_decimal():
    lua = runtime()
    model = req(lua, "youless_model")
    r = model.from_a(lua.eval(b'{ cnt = " 37420,724", pwr = -510 }'))
    assert r.power == -510
    assert abs(r.import_kwh - 37420.724) < 1e-6


def test_is_youless():
    lua = runtime()
    model = req(lua, "youless_model")
    assert model.is_youless(lua.eval(b'{ model = "LS120", mac = "72:b8:ad:14:39:24" }'))
    assert not model.is_youless(lua.eval(b'{ model = "Envoy" }'))
    assert not model.is_youless(None)


def test_deadband():
    lua = runtime()
    model = req(lua, "youless_model")
    last = lua.eval(b'{ v = 1000, t = 1000 }')
    assert not model.power_due(last, 1100, 1030)      # small change, 30 s
    assert model.power_due(last, 1600, 1016)          # jump of 600 W after 16 s
    assert not model.power_due(last, 1600, 1010)      # jump, but within 15 s
    assert model.power_due(last, 1001, 1060)          # once a minute
    assert model.power_due(None, 5, 0)
    assert model.totals_due(None, 0) and not model.totals_due(100, 399) and model.totals_due(100, 400)
