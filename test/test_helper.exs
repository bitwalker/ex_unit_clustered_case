{_, 0} = System.cmd("epmd", ["-daemon"])
Node.start(:"primary@127.0.0.1", :longnames)
ExUnit.start()
