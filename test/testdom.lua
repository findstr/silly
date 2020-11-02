local dom = require "http.dom"
local testaux = require "testaux"
return function()
	local tree = dom.parse [[
		<hello foo=bar class="c1 c2">
			&#20320;&#22909;世界&lt;&gt;&amp;&quot;
		</hello>
	]]
	testaux.asserteq(tree.name, "hello", "name")
	testaux.asserteq(tree.child[1], '你好世界<>&"', 'child')
	testaux.asserteq(tree.class[1], "c1", "class c1")
	testaux.asserteq(tree.class[2], "c2", "class c2")
	testaux.asserteq(tree.attr.foo, "bar", "attr.foo")
	testaux.asserteq(tree.attr.class, "c1 c2", "attr.class")
end

