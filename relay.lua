local net = require("luanode.net");
local cjson = require("cjson");

function getconfig()
  f = io.open("relay.json", "r");
  local t = f:read("*all")
  f:close();
  return cjson.decode(t);
end

config = getconfig();

relayclients = {};
--
-- this should be the serial input 
-- but we do it with a connection to a tcp test server
--
uart = net.createConnection(5555, "127.0.0.1");
uart:on("connect", function() end);
uart:on("data", function(self, chunk)
    for cl,_ in pairs(relayclients) do
      cl:write(chunk);
    end
  end);
uart:on("error", function()
  end);

if config["tcp"] ~= nil then
  kplex = net.createConnection(config["port"], config["host"]);
  kplex:on("connect", function() end);
  kplex:on("data", function(chunk)
    uart:write(chunk);
  end);
  kplex:on("error", function()
  end);
end

if config["udp"] ~= nil then
 -- TODO
end

ec = net.createServer(function (self, connection)
  relayclients[connection] = true;
  connection:addListener("data", function (self, chunk)
    uart:write(chunk); -- don't expect data here, but if we get some use it
  end);
  connection:addListener("end", function (self)
    relayclients[self] = nil;
    self:finish();
  end);
end);
ec:listen(config["listen"]);

--
--  A table of MIME types.
--
mime = {};
mime[ "html" ]  = "text/html";
mime[ "txt"  ]  = "text/plain";
mime[ "json" ]  = "application/json";
mime[ "jpg"  ]  = "image/jpeg";
mime[ "jpeg" ]  = "image/jpeg";
mime[ "gif"  ]  = "image/gif";
mime[ "png"  ]  = "image/png";

router = {};

function mimetype(file)
  --
  -- Find the suffix to get the mime.type.
  --
  _, _, ext  = string.find( file, "\.([^\.]+)$" );
  if ( ext == nil ) then
    ext = "html";
  -- HACK
  end

  typ = mime[ext];
  if ( typ == nil ) then
    typ = 'text/plain' ;
  end

  return typ;
end

function sendHeaders(client, mimetype)
  sendHeaders2(client, "200 OK", "text/html");
end

function sendHeaders2(client, code, mimetype)
  client:write("HTTP/1.0 " .. code .. "\r\n" );
  client:write("Server: nmea-relay " .. "0.1" .. "\r\n");
  client:write("Content-type: " .. mimetype  .. "\r\n" );
  client:write("Connection: close\r\n\r\n" );
end

--
--  Send the given error message to the client.
--  Return the length of data sent to the client so we know what to log.
--
function sendError( client, status, str )
  sendHeaders2(client, status .. " OK", "text/html");
  client:write("<html><head><title>Error</title></head>");
  client:write("<body><h1>Error</h1");
  client:write("<p>" .. str .. "</p></body></html>");
  client:write(message);
end

--
--  Utility function:
-- Determine whether the given file exists.
--
function fileExists (file)
  local f = io.open(file, "rb");
  if f == nil then
    return false;
  else
    f:close();
    return true;
  end
end

--
--  Utility function:
--  Does the string end with the given suffix?
--
function string.endsWith(String,End)
  return End=='' or string.sub(String,-string.len(End))==End
end

--
-- Utility function:  URL encoding function
--
function urlEncode(str)
  if (str) then
    str = string.gsub (str, "\n", "\r\n")
    str = string.gsub (str, "([^%w ])",
    function (c) return string.format ("%%%02X", string.byte(c)) end)
    str = string.gsub (str, " ", "+")
  end
  return str;
end

--
-- Utility function:
-- URL decode function
--
function urlDecode(str)
  str = string.gsub (str, "+", " ")
  str = string.gsub (str, "%%(%x%x)", function(h) return string.char(tonumber(h,16)) end)
  str = string.gsub (str, "\r\n", "\n")
  return str
end

function processGet(client, path, major, minor, headers, body)
  if string.sub(path, 1, 1) == '/' then
    path = string.sub(path, 2);
  end
  --
  -- Local file
  --
  file = path;

  --
  -- Add a trailing "index.html" to paths ending in / if such
  -- a file exists.
  --
  if ( string.endsWith( file, "/" ) ) then
    tmp = file .. "index.html";
    if ( fileExists( tmp ) ) then
      file = tmp;
    end
  end

  --
  -- Open the file and return an error if it fails.
  --
  if ( fileExists( file ) == false ) then
    sendError( client, 404, "File not found " .. urlEncode( path ) );
    return;
  end

  --
  -- Send out the header.
  --
  sendHeaders(client, mimetype(file));

  --
  -- Read the file, and then serve it.
  --
  f = io.open( file, "rb" );
  local t = f:read("*all")
  f:close();
  client:write(t );
end

function processPost(client, path, major, minor, headers, body)
  params = {};
  if headers["Content-Type"] == "application/x-www-form-urlencoded" then
    for k, v in string.gmatch(body, "([^=]+)=([^&]*)&") do
      params[k] = v;
    end
  end
  if router[path] ~= nil then
    router[path](client, header, params, body);
  end
end

function processHttpRequest(client, path, headers, body)
  --
  -- We only handle GET and POST requests.
  --
  if ( method == "GET" ) then
    processGet(client, path, major, minor, headers, body);
  elseif ( method == "POST" ) then
    processPost(client, path, major, minor, headers, body);
  else
    error = "Method not implemented";

    if ( method == nil ) then
      error = error .. ".";
    else
      error = error .. ": " .. urlEncode( method );
    end

    sendError(client, 501, error );
  end
  client:close();
end


ws = net.createServer(function (self, connection)
 connection["data"]="";
 connection:addListener("data", function(self, chunk)
   data = self["data"] .. chunk;
   local i,j = string.find( data, '\r\n\r\n' );
   if i==nil then
     self["data"] = data;
   else
     _, _, method, path, major, minor  = string.find(data, "([A-Z]+) (.+) HTTP/(%d).(%d)");
     path = urlDecode( path );
     headers = {};
     for k, v in string.gmatch(data, "([%w-]+)%s*:%s*([^%c]+)%c+") do
       headers[k] = v;
     end
     if headers["Content-Length"]==nil then
       processHttpRequest(self, path, headers, nil);
       self:finish();
     else
       local len = headers["Content-Length"];
       i,j = string.find(data, '\r\n\r\n' );
       body = string.sub(data, j+1);
       if string.len(body) >= tonumber(len) then
         processHttpRequest(self, path, headers, body);
         self:finish();
       else
         self["data"] = data;
       end
     end
   end
 end);
 connection:addListener("end", function(self)
   self:finish();
 end);
end);
ws:listen(80);

--
-- provide some post functions
--

router["/update"] = function(client, headers, params, body)
  sendHeaders(client, "text/html");
  client:write("<html><head><title>Server Updated</title></head>" );
  client:write("<body>");
  client:write("<h1>Server Updated</h1><p>As per your request.</p>");
  file = io.open("relay.json", "w");
  file:write(cjson.encode(params));
  file:close();
  client:write("</body></html>");
end

process:loop();
