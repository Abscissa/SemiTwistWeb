/// Written in the D programming language.

module semitwistWeb.util;

import std.array;
import std.conv;
import std.digest.md;
import std.digest.sha;
import std.file;
import std.range;
import std.string;
import std.traits;
import std.typecons;

import vibe.vibe;

import arsd.dom;
import mustacheLib = mustache;
import mysql.db;
import semitwist.util.all;
mixin importConf;

enum semitwistWebVersion = "0.0.1";

alias mustacheLib.MustacheEngine!string Mustache;
bool mustacheInited = false;
private Mustache _mustache;
@property ref Mustache mustache()
{
	if(!mustacheInited)
	{
		_mustache.ext     = "html";
		_mustache.path    = getExecPath()~"../res/templates/";
		_mustache.level   = Mustache.CacheLevel.once;
		_mustache.handler((tagName) => onMustacheError(tagName));
	}
	
	return _mustache;
}

private string onMustacheError(string tagName)
{
	throw new Exception("Unknown Mustache variable name: "~tagName);
}

string createUnsafeScoped(string typeName, string varName, string ctorParams="")
{
	if(ctorParams != "")
		ctorParams = ", "~ctorParams;

	return q{
		enum $VAR_NAME_bufSize =
			__traits(classInstanceSize, $TYPE_NAME) +
			classInstanceAlignment!($TYPE_NAME);
		ubyte[$VAR_NAME_bufSize] $VAR_NAME_buf;
		auto $VAR_NAME = emplace!($TYPE_NAME)($VAR_NAME_buf $CTOR_PARAMS);
	}
	.replace("$VAR_NAME", varName)
	.replace("$CTOR_PARAMS", ctorParams)
	.replace("$TYPE_NAME", typeName);
}

void deactivateLink(Element link)
{
	link.removeAttribute("href");
	link.className = "inactive-link";
	link.tagName = "span";
}

void removeAll(Element elem, string selector)
{
	foreach(ref elemToRemove; elem.getElementsBySelector(selector))
		elemToRemove.outerHTML = "";
}

/++
Sample usage:

	struct Foo {
		int i; string s;
	}

	auto doc = new Document("
		<body>
			<h1>Foo:</h1>
			<div class="foo">
				<h2 class=".foo-int">(placeholder)</h2>
				<p class=".foo-str">(placeholder)</p>
				<hr />
			</div>
		</body>
		", true, true);

	fill!(Foo[])(
		doc.requireSelector(".foo"),
		[Foo(10,"abc"), Foo(20,"def")],
		(stamp, index, foo) {
			stamp.requireSelector(".foo-int").innerHTML = text("#", index, " ", foo.i);
			stamp.requireSelector(".foo-str").innerHTML = foo.s;
			return stamp;
		}
	)
	
	/+
	Result:
		<body>
			<h1>Foo:</h1>
			<div class="foo">
				<h2 class=".foo-int">#0: 10</h2>
				<p class=".foo-str">abc</p>
				<hr />
			</div>
			<div class="foo">
				<h2 class=".foo-int">#1: 20</h2>
				<p class=".foo-str">def</p>
				<hr />
			</div>
		</body>
	+/
	writeln(doc);
+/
//TODO: fill() needs a way to do a plain old 0..x with no data
void fill(T)(
	Element elem, T collection,
	Element delegate(Element, size_t, ElementType!T) dg
) if(isInputRange!T)
{
	auto elemTemplate = elem.cloned;
	string finalHtml;
	for(size_t i=0; !collection.empty; i++)
	{
		auto stamp = elemTemplate.cloned;
		auto newElem = dg(stamp, i, collection.front);
		finalHtml ~= newElem.toString();
		collection.popFront();
	}
	elem.outerHTML = finalHtml;
}

string insertDashes(string str)
{
	string ret;

	int i;
	for(i = 0; i+5 < str.length; i += 5)
	{
		if(i > 0)
			ret ~= '-';

		ret ~= str[i..i+5];
	}

	if(i < str.length)
	{
		ret ~= '-';
		ret ~= str[i..$];
	}

	return ret;
}

bool isSSLReverseProxy(HttpServerRequest req)
{
	// Newer versions of IIS automatically set this
	if(auto valPtr = "X-ARR-SSL" in req.headers)
	if((*valPtr).strip() != "")
		return true;
	
	// Nginx: Include this in the section of your nginx configuration file
	// that sets up a reverse proxy for this program:
	//   proxy_set_header X-SSL-Protocol $ssl_protocol;
	if(auto valPtr = "X-SSL-Protocol" in req.headers)
	if((*valPtr).strip() != "")
		return true;
	
	// Some reverse proxies can be configured to set this
	if(auto valPtr = "X-USED-SSL" in req.headers)
	if((*valPtr).strip().toLower() == "true")
		return true;
	
	return false;
}

@property string clientIPs(HttpServerRequest req)
{
	immutable headerName = "X-Forwarded-For";
	if(headerName in req.headers)
	{
		auto ips = req.headers[headerName].strip();
		if(ips != "")
			return ips;
	}
	
	return req.peer;
}

string extToMime(string ext)
{
	switch(ext.toLower())
	{
	case ".txt":  return "text/plain";
	case ".htm":  return "text/html";
	case ".html": return "text/html";
	case ".xml":  return "application/xml";
	case ".xsl":  return "application/xml";
	case ".css":  return "text/css";
	case ".jpeg": return "image/jpeg";
	case ".jpg":  return "image/jpeg";
	case ".png":  return "image/png";
	case ".gif":  return "image/gif";
	case ".zip":  return "application/zip";
	case ".z":    return "application/x-compress";
	case ".wav":  return "audio/wav";
	case ".mp3":  return "audio/mpeg3";
	case ".avi":  return "video/avi";
	default:      return "application/octet-stream";
	}
}

string commentToHTML(string str)
{
	return str
		.replace("&", "&amp;")
		.replace("<", "&lt;")
		.replace(">", "&gt;")
		.replace("\n", "<br />\n");
}

Nullable!T paramAs(T)(HttpServerRequest req, string name)
{
	T value;

	try
		value = to!T(req.params[name]);
	catch(ConvException e)
		return Nullable!T();
	
	return Nullable!T(value);
}

T getNullable(T)(Row row, size_t index) if(isSomeString!T)
{
	if(row.isNull(index))
		return null;

	return row[index].coerce!T();
}

Nullable!T getNullable(T)(Row row, size_t index) if(!isSomeString!T)
{
	if(row.isNull(index))
		return Nullable!T();

	return Nullable!T( row[index].coerce!T() );
}

ubyte[8] genSalt()
{
	ubyte[8] ret;
	ret[] = randomBytes(8)[];
	return ret;
}

ubyte[] hashPass(ubyte scheme, ubyte[8] salt, string pass)
{
	switch(scheme)
	{
	case 0x01:
		return scheme ~ salt ~ md5Of(cast(string)(salt[]) ~ pass);

	case 0x02:
		return scheme ~ salt ~ sha1Of(cast(string)(salt[]) ~ pass);

	default:
		throw new Exception("Unsupported password scheme: 0x%.2X".format(scheme));
	}
}

/// Returns: Pass ok?
bool validatePass(string pass, ubyte[] saltedHash)
{
	auto scheme = saltedHash[0];
	if(
		scheme < 0x01 || scheme > 0x02 ||
		(scheme == 0x01 && saltedHash.length != 25) ||
		(scheme == 0x02 && saltedHash.length != 29)
	)
	{
		logWarn(
			"Validating against unsupported password scheme: 0x%.2X (length: %s) (Assuming not a match)",
			scheme, saltedHash.length
		);
		return false;
	}
		
	ubyte[8] salt = saltedHash[1..9];
	return saltedHash == hashPass(scheme, salt, pass);
}

string toEmailString(SysTime st)
{
	auto dt = cast(DateTime) st;

	static immutable char[3][12] monthStrings     = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
	static immutable char[3][ 7] dayOfWeekStrings = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

	auto tzOffset = st.timezone.utcOffsetAt(st.stdTime);
	auto tzAbsOffset = abs(tzOffset);

	return "%s, %s %s %.4s %.2s:%.2s:%.2s %s%.2s%.2s".format(
		dayOfWeekStrings[dt.dayOfWeek],
		dt.day, monthStrings[dt.month - 1], dt.year,
		dt.hour, dt.minute, dt.second,
		tzOffset < seconds(0)? "-" : "+",
		tzAbsOffset.hours,
		tzAbsOffset.minutes
	);
}

// Usage:
//   mixin importConf;  // Imports 'res/conf.d' into symbol 'Conf'
//   writefln("Site '%s' uses DB at %s", Conf.siteTitle, Conf.dbHost);
//
// If 'res/conf.d' doesn't exist, a compile-time error is generated.
mixin template importConf()
{
	static if( __traits(compiles, (){ import conf; }) )
	{
		import Conf = conf;
	}
	else
		static assert(false,
			"Missing 'res/conf.d'...\n"~
			"    Before you can compile, you must copy 'res/conf-sample.d' to 'res/conf.d'\n"~
			"    and fill in the settings inside."
		);
}

private enum _confErrorMsg =
"Error in 'conf.d':
res/conf.d: ";
version(Windows)
	immutable confErrorMsg = ctfe_substitute(_confErrorMsg, "/", "\\");
else
	immutable confErrorMsg = _confErrorMsg;

// Validate conf.d:
static assert(
	Conf.urlBase.length > 0  &&
	Conf.urlBase[0  ] == '/' &&
	Conf.urlBase[$-1] == '/',
	confErrorMsg~"urlBase must start and end with a slash"
);
static assert(
	Conf.host.strip().length > 0,
	confErrorMsg~"host cannot not be blank"
);
static assert(
	Conf.host.strip() == Conf.host,
	confErrorMsg~"host cannot have leading or trailing whitespace"
);
static assert(
	Conf.host[$-1] != '/',
	confErrorMsg~"host cannot end with a slash"
);
static assert(
	Conf.host.toLower().startsWith("http://") ||
	Conf.host.toLower().startsWith("https://"),
	confErrorMsg~"host must begin with either http:// or https://"
);
