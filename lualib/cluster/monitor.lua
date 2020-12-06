local html = [[
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Cluster Monitor</title>
</head>
<body>

<script src="https://cdn.jsdelivr.net/npm/vue/dist/vue.js"></script>
<script src="https://cdn.staticfile.org/axios/0.18.0/axios.min.js"></script>
<script src="https://cdn.bootcdn.net/ajax/libs/ant-design-vue/1.7.1/antd-with-locales.min.js"></script>
<link href="https://cdn.bootcdn.net/ajax/libs/ant-design-vue/1.7.1/antd.min.css" rel="stylesheet">
<script src="https://cdn.bootcdn.net/ajax/libs/ant-design-vue/1.7.1/antd.min.js"></script>

<div id="app">
<template>
  <a-card title="服务列表">
	<a-card v-for="service in services" :key="service.name">
	  <a-descriptions :title="service.name" bordered>
    <a-descriptions-item label="Epoch">
			{{ service.epoch }}
    </a-descriptions-item>
    <a-descriptions-item label="Status" :span="3">
      <a-badge :color="service.status_color" :text="service.status" />
    </a-descriptions-item>
		<a-descriptions-item label="PID">
			{{ service.pid }} <br/>
    </a-descriptions-item>
		<a-descriptions-item label="CPU">
			uptime_in_seconds: {{ service.uptime_in_seconds }} <br/>
			uptime_in_days : {{ service.uptime_in_days }} <br/>
			cpu_sys: {{ service.cpu_sys }} <br/>
			cpu_user: {{ service.cpu_user }}
    </a-descriptions-item>
		<a-descriptions-item label="Memory">
			used: {{service.memory_used}} Byte <br/>
			rss: {{service.memory_rss}} Byte <br/>
			fragmentation_ratio: {{service.memory_fragmentation_ratio}} <br/>
			allocator: {{service.memory_allocator}}
    </a-descriptions-item>

		<a-descriptions-item label="Message">
			{{ service.message_pending }}
    </a-descriptions-item>

		<a-descriptions-item label="Listen">
			{{service.listen}}
    </a-descriptions-item>

		<a-descriptions-item label="Server">
			version: {{service.version}} <br/>
			multiplexing_api: {{ service.multiplexing_api}} <br/>
			timer_resolution: {{ service.timer_resolution }} <br/>
    </a-descriptions-item>
  </a-descriptions>
	</a-card>
</template>
</div>

<script>
var app = new Vue({
  el: '#app',
  data: {services: []}
})

setInterval(()=>{
	var url = window.location.origin;
	axios
	.get(url + "/status")
	.then(function(resp) {
		resp.data.forEach(function(s) {
			if (s.status == "run")
				s.status_color = "green";
			else if (s.status == "down")
				s.status_color = "red";
			else
				s.status_color = "yellow";
		});
		app.services = resp.data
	})
	.catch(function(err) {
		console.log(err);
	});
}, 1000)
</script>
</body>
</html>
]]

return html

