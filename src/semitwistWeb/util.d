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
import vibe.utils.dictionarylist;

import arsd.dom;
import mustacheLib = mustache;
import mysql.db;
import semitwist.util.all;
import semitwistWeb.conf;

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

void stLog
	(LogLevel level, /*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)
	(auto ref T args)
{
	log!(level, /*__MODULE__, __FUNCTION__,*/ __FILE__, __LINE__)( "%s", text(args)	);
}
void stLogTrace     (/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(auto ref T args) { stLog!(LogLevel.trace     /*, mod, func*/, file, line)(args); }
void stLogDebugV    (/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(auto ref T args) { stLog!(LogLevel.debugV    /*, mod, func*/, file, line)(args); }
void stLogDebug     (/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(auto ref T args) { stLog!(LogLevel.debug_    /*, mod, func*/, file, line)(args); }
void stLogDiagnostic(/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(auto ref T args) { stLog!(LogLevel.diagnostic/*, mod, func*/, file, line)(args); }
void stLogInfo      (/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(auto ref T args) { stLog!(LogLevel.info      /*, mod, func*/, file, line)(args); }
void stLogWarn      (/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(auto ref T args) { stLog!(LogLevel.warn      /*, mod, func*/, file, line)(args); }
void stLogError     (/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(auto ref T args) { stLog!(LogLevel.error     /*, mod, func*/, file, line)(args); }
void stLogCritical  (/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(auto ref T args) { stLog!(LogLevel.critical  /*, mod, func*/, file, line)(args); }

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

bool isSSLReverseProxy(HTTPServerRequest req)
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

@property string clientIPs(HTTPServerRequest req)
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

Nullable!T paramAs(T)(HTTPServerRequest req, string name)
{
	T value;

	try
		value = to!T(req.params[name]);
	catch(ConvException e)
		return Nullable!T();
	
	return Nullable!T(value);
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
		stLogWarn(
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
		tzAbsOffset.split!"hours",
		tzAbsOffset.split!"minutes"
	);
}

//TVal getRequired(TVal, TCase)(DictionaryList!(TVal, TCase) dict, string key)
string getRequired(FormFields dict, string key)
{
	try
		return dict[key];
	catch(Exception e)
		throw new MissingKeyException(key);
}

//TODO: This should go in SemiTwistDTools
string nullableToString(T)(Nullable!T value, string ifNull = "N/A")
{
	return value.isNull? ifNull : to!string(value.get());
}

Enum toEnum(Enum)(string name) if(is(Enum == enum))
{
	import std.traits : fullyQualifiedName;
	foreach(value; __traits(allMembers, Enum))
	{
		if(value == name)
			return __traits(getMember, Enum, value);
	}
	
	throw new Exception("enum '"~ fullyQualifiedName!Enum ~"' doesn't have member: "~name);
}
