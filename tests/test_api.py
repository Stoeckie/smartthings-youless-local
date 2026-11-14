"""youless_api.get reads until the YouLess closes the connection, also when cosock raises on close."""
from run_lua import runtime

MOCK = rb'''
CHUNKS = {}
MODE = "closed"   -- "closed": nil, "closed", partial at the end; "raise": error like cosock does
package.loaded["cosock.socket"] = { tcp = function()
  local i = 0
  return {
    settimeout = function() end,
    connect = function() return 1 end,
    send = function(_, s) return #s end,
    close = function() end,
    receive = function(_, n)
      i = i + 1
      if CHUNKS[i] then return CHUNKS[i] end
      if MODE == "raise" then error("socket receive returned nil data") end
      return nil, "closed", TAIL or ""
    end,
  }
end }
package.loaded["st.json"] = { decode = function(s) return { raw = s } end }
'''


def setup(chunks, mode, tail=b""):
    lua = runtime()
    lua.execute(MOCK)
    g = lua.globals()
    g.MODE = mode.encode()
    g.TAIL = tail
    t = lua.table()
    for i, c in enumerate(chunks, 1):
        t[i] = c
    g.CHUNKS = t
    return lua


def test_close_with_partial():
    lua = setup([b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n[{\"pwr\":"], "closed", tail=b"22}]")
    st, body = lua.execute(b'return require("youless_api").get("h", "/e")')
    assert st == 200 and body == b'[{"pwr":22}]'


def test_cosock_raises_on_close():
    lua = setup([b"HTTP/1.0 200 OK\r\n\r\n", b'{"model":"LS120"}'], "raise")
    st, body = lua.execute(b'return require("youless_api").get("h", "/d")')
    assert st == 200 and body == b'{"model":"LS120"}'


def test_nothing_received():
    lua = setup([], "raise")
    st, err = lua.execute(b'return require("youless_api").get("h", "/d")')
    assert st is None and b"receive" in err
