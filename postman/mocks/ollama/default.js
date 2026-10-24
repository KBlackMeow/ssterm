// Contract fixture: https://docs.ollama.com/capabilities/tool-calling
// Only /api/chat is modeled. No model inference or command execution occurs.
const http = require('http');
http.createServer(async (req, res) => {
  if (req.method !== 'POST' || req.url !== '/api/chat') {
    res.writeHead(501, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'Endpoint not modeled' }));
  }
  const body = req.body;
  const bash = body?.tools?.find(tool => tool.function?.name === 'bash');
  if (!body?.model || !Array.isArray(body.messages) || !bash ||
      !bash.function.parameters?.properties?.risk_reason) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'Expected model, messages and native bash schema' }));
  }
  const results = body.messages.filter(message => message.role === 'tool');
  const message = results.length ? {
    role: 'assistant', content: `Directory: ${results[0].content}`,
  } : {
    role: 'assistant', content: '',
    tool_calls: [{ function: {
      name: 'bash',
      arguments: {
        command: 'pwd', reason: 'Find current directory',
        risk_level: 'normal', risk_reason: 'Read only',
      },
    } }],
  };
  if (results.length) {
    const calls = body.messages.find(item => item.role === 'assistant')?.tool_calls;
    if (results[0].tool_name !== 'bash' || !calls?.[0]?.function?.arguments?.command) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'Expected native assistant tool_calls and role:tool result' }));
    }
  }
  const response = { message, done: true, done_reason: 'stop', prompt_eval_count: 40, eval_count: 12 };
  res.writeHead(200, { 'Content-Type': body.stream ? 'application/x-ndjson' : 'application/json' });
  res.end(JSON.stringify(response) + (body.stream ? '\n' : ''));
}).listen(process.env.PORT || 4962);
