/// Written in the D programming language.

module semitwistWeb.doc;

import std.array;
import std.conv;
import std.range;
import std.stdio;
import std.traits;
import std.typecons;
import std.typetuple;

import vibe.vibe;
import arsd.dom;
import semitwist.util.all;

import semitwistWeb.db;
import semitwistWeb.form;
import semitwistWeb.session;
import semitwistWeb.util;

enum staticsUrl = Conf.urlBase ~ Conf.staticsVirtualPath;

void clearDocHelperCache()
{
	mustache.clearCache();
}

void addCommonContext(Mustache.Context c, SessionData sess)
{
	// Basic information
	string mainFrame(string content)
	{
		c["pageBody"] = content;
		return mustache.render("frame-main", c);
	}

	c["mainFrame"]          = &mainFrame;
	c["urlBase"]            = Conf.urlBase;
	c["staticsUrl"]         = staticsUrl;
	c["stylesheetFilename"] = staticsUrl ~ "style.css";

	// Session information
	c.useSection(sess.isLoggedIn? "loggedIn" : "loggedOut");
	if(sess.oneShotMessage != "")
	{
		c.useSection("hasPageMessage");
		c["pageMessage"] = sess.oneShotMessage;
	}
	
	// Pages
	foreach(page; PageBase.registeredPages)
	{
		if(page.numParams == 0)
			c[page.viewName] = page.buildUrl();
		else if(page.numParams == 1)
			c[page.viewName] = (string content) => page.buildUrl( content );
		else
			c[page.viewName] = (string content) => page.buildUrl( content.split("|") );
	}
}

void addFormContext(Mustache.Context c, SessionData sess, string[] formNames)
{
	foreach(formName; formNames)
		c.addFormContext(sess, formName);
}

void addFormContext(Mustache.Context c, SessionData sess, string formName)
{
	auto submissionPtr = formName in sess.submissions;
	if(!submissionPtr)
		throw new Exception(
			text("Form '", formName, "' can't be found in SessionData.submissions.")
		);
	
	c["form-"~formName] = HtmlForm.get(formName).toHtml(*submissionPtr);
}

/+
private ref string pageSelect(alias page)(LoginState state)
{
	if(state == LoginState.Out)
		return page!(LoginState.Out);
	else
		return page!(LoginState.In);
}
+/

struct DefinePage
{
	string method;
	string dispatcher;
	string name;
	string urlRoute;
	string targs;
	
	this(string method, string dispatcher, string name, string urlRoute, string targs="")
	{
		this.method     = method;
		this.dispatcher = dispatcher;
		this.name       = name;
		this.urlRoute   = urlRoute;
		this.targs      = targs;
	}
	
	string _makePageStr; /// Treat as private
}

string definePages(DefinePage[] pages)
{
	string str;

	foreach(ref page; pages)
	{
		auto method = page.method=="ANY"? "Nullable!HttpMethod()" : "Nullable!HttpMethod(HttpMethod."~page.method~")";
		page._makePageStr = "makePage!("~method~", "~page.dispatcher~", `"~page.name~"`, `"~page.urlRoute~"`, "~page.targs~")()";
	}

	str ~= "import std.typecons : Nullable;\n";
	
	foreach(page; pages)
		str ~= "Page!("~page.targs~") page_"~page.name~";\n";
	
	foreach(page; pages)
		str ~=
			"template page(string name) if(name == `"~page.name~"`)\n"~
			"    { alias page_"~page.name~" page; }\n";
	
	str ~= "void initPages() {\n";

	foreach(page; pages)
		str ~= "    page!`"~page.name~"` = "~page._makePageStr~";\n";

	foreach(page; pages)
		str ~= "    page!`"~page.name~"`.register();\n";

	str ~= "}\n";

	return str.replace("\n", "");
}

auto makePage(alias method, alias dispatcher, string name, string urlRoute, TArgs...)()
{
	enum sections = getUrlRouteSections(urlRoute);
	static assert(
		TArgs.length == sections.length-1,
		"Wrong number of argument types for makePage:\n"~
		"    URL route: "~urlRoute~"\n"~
		"    Received "~to!string(TArgs.length)~" args but expected "~to!string(sections.length-1)~"."
	);
	
	return new Page!(TArgs)(name, sections, urlRoute, method, (a,b) => dispatcher!name(a,b));
}

private string[] getUrlRouteSections(string urlRoute)
{
	enum State { normal, tag, wildcard }

	string[] sections;
	size_t sectionStart = 0;
	State state;

	urlRoute = urlRoute ~ '\0';
	foreach(i; 0..urlRoute.length)
	{
		final switch(state)
		{
		case State.normal:
			if(urlRoute[i] == ':')
			{
				sections ~= urlRoute[sectionStart..i];
				state = State.tag;
			}
			else if(urlRoute[i] == '*')
			{
				sections ~= urlRoute[sectionStart..i];
				state = State.wildcard;
			}
			break;

		case State.tag:
		case State.wildcard:
			if(urlRoute[i] == '/' || urlRoute[i] == '\0')
			{
				state = State.normal;
				sectionStart = i;
			}
			else
			{
				if(state == State.wildcard)
					throw new Exception("Unexpected character in urlRoute after *: Expected / or end-of-string");
			}
			break;
		}
	}
	
	if(sectionStart == urlRoute.length)
		sections ~= "";
	else
		sections ~= urlRoute[sectionStart..$-1]; // Exclude the added \0

	return sections;
}

alias void delegate(HttpServerRequest, HttpServerResponse) PageHandler;

abstract class PageBase
{
	protected string _name;
	final @property string name()
	{
		return _name;
	}
	
	protected string _viewName;
	final @property string viewName()
	{
		return _viewName;
	}

	/// HTTP Handler
	PageHandler handler;

	/// Null implies "any method"
	Nullable!HttpMethod method;
	
	protected int _numParams;
	final @property int numParams()
	{
		return _numParams;
	}

	protected string[] urlSections;

	protected string _urlRouteRelativeToBase;
	final @property string urlRouteRelativeToBase()
	{
		return _urlRouteRelativeToBase;
	}
	final @property string urlRouteAbsolute()
	{
		return Conf.urlBase ~ _urlRouteRelativeToBase;
	}

	private static PageBase[string] registeredPages;
	static PageBase get(string name)
	{
		return registeredPages[name];
	}
	
	private static string[] registeredPageNames;
	private static bool registeredPageNamesInited = false;
	static string[] getNames()
	{
		if(!registeredPageNamesInited)
		{
			registeredPageNames = registeredPages.keys;
			registeredPageNamesInited = true;
		}
		
		return registeredPageNames;
	}
	
	final void register()
	{
		if(_name in registeredPages)
			throw new Exception(text("A page named '", _name, "' is already registered."));
		
		registeredPages[_name] = this;
		registeredPageNames = null;
		registeredPageNamesInited = false;
	}
	
	static bool isRegistered(string pageName)
	{
		return !!(pageName in registeredPages);
	}

	final bool isRegistered()
	{
		return
			_name in registeredPages && this == registeredPages[_name];
	}

	final void unregister()
	{
		if(!isRegistered())
		{
			if(_name in registeredPages)
				throw new Exception(text("Cannot unregister page '", _name, "' because it's unequal to the registered page of the same name."));
			else
				throw new Exception(text("Cannot unregister page '", _name, "' because it's not registered."));
		}
		
		registeredPages.remove(_name);
		registeredPageNames = null;
		registeredPageNamesInited = false;
	}

	/// This is a low-level tool provided for the sake of generic code.
	/// In general, you should use 'Page.url' or 'Page.urlSink' instead of this
	/// because those verify both the types and number of args at compile-time.
	/// This, however, only verifies number of args, and only at runtime.
	final string buildUrl()(string[] args...)
	{
		if(args.length != _numParams)
			throw new Exception(text("Expected ", _numParams, " args, not ", args.length));
		
		if(_numParams == 0)
			return urlSections[0];
		
		Appender!string sink;
		buildUrl(sink, args);
		return sink.data;
	}

	///ditto
	final void buildUrl(Sink)(ref Sink sink, string[] args...) if(isOutputRange!(Sink, string))
	{
		if(args.length != _numParams)
			throw new Exception(text("Expected ", _numParams, " args, not ", args.length));

		size_t index=0;
		foreach(arg; args)
		{
			sink.put(urlSections[index]);
			sink.put(arg);
			index++;
		}

		sink.put(urlSections[$-1]);
	}
}

final class Page(TArgs...) : PageBase
{
	enum numSections = TArgs.length+1;

	private this(
		string name,
		string[numSections] urlSections, string urlRouteRelativeToBase,
		Nullable!HttpMethod method, PageHandler handler
	)
	{
		this._name = name;
		this._viewName = "page-" ~ name;
		this.urlSections = urlSections[].dup;
		this._urlRouteRelativeToBase = urlRouteRelativeToBase;
		this.handler = handler;
		this._numParams = TArgs.length;
		
		if(method.isNull)
			this.method.nullify();
		else
			this.method = method;
		
		this.urlSections[0] = Conf.urlBase ~ this.urlSections[0];
	}
	
	string url(TArgs args)
	{
		if(_numParams == 0)
			return urlSections[0];
		
		Appender!string sink;

		// Workaround for DMD Issue #9894
		//urlSink(sink, args);
		this.callUrlSink(sink, args);

		return sink.data;
	}

	void urlSink(Sink)(ref Sink sink, TArgs args) if(isOutputRange!(Sink, string))
	{
		size_t index=0;
		foreach(arg; args)
		{
			sink.put(urlSections[index]);
			sink.put(to!string(arg));
			index++;
		}

		sink.put(urlSections[$-1]);
	}
}

// Workaround for DMD Issue #9894
//TODO: Remove this workaround once DMD 2.063 is required
private void callUrlSink(TPage, Sink, TArgs...)(TPage p, ref Sink sink, TArgs args)
{
	p.urlSink!(Sink)(sink, args);
}

void addPage(UrlRouter router, PageBase page)
{
	void addPageImpl(string urlRoute)
	{
		if(page.method.isNull)
			router.any(urlRoute, page.handler);
		else
			router.match(page.method.get(), urlRoute, page.handler);
	}

	addPageImpl(page.urlRouteAbsolute);

	if(page.urlRouteAbsolute == Conf.urlBase && Conf.urlBase != "")
		addPageImpl(Conf.urlBase[0..$-1]);  // Sans trailing slash
}

// For the unittests below
string testDispatcherResult;
private void testDispatcher(string pageName)(HttpServerRequest req, HttpServerResponse res)
{
	testDispatcherResult = "Did "~pageName;
}

//TODO: This can probably be changed to a normal unittest once using Vibe.d v0.7.14
void runDocHelperUnittest()
{
	import std.stdio;
	writeln("Unittest: docHelper.makePage"); stdout.flush();
	
	enum m = Nullable!HttpMethod();

	auto p1 = makePage!(m, testDispatcher, "name", "client/*/observer/:oid/survey", int, int)();
	assert(p1.url(10, 20)   == Conf.urlBase~"client/10/observer/20/survey");
	assert(p1.url(111, 222) == Conf.urlBase~"client/111/observer/222/survey");
	
	static assert( __traits( compiles, p1.url(111, 222) ));
	static assert(!__traits( compiles, p1.url(111, `222`) ));
	static assert(!__traits( compiles, p1.url(111) ));
	static assert(!__traits( compiles, p1.url(111, 222, 333) ));

	static assert( __traits( compiles, makePage!(m, testDispatcher, "name", "client/*/observer/:oid/survey", int, int      )() ));
	static assert( __traits( compiles, makePage!(m, testDispatcher, "name", "client/*/observer/:oid/survey", int, string   )() ));
	static assert(!__traits( compiles, makePage!(m, testDispatcher, "name", "client/*/observer/:oid/survey", int           )() ));
	static assert(!__traits( compiles, makePage!(m, testDispatcher, "name", "client/*/observer/:oid/survey", int, int, int )() ));
	
	assert(makePage!(m, testDispatcher, "name", "client")           ().url()        == Conf.urlBase~"client");
	assert(makePage!(m, testDispatcher, "name", "")                 ().url()        == Conf.urlBase~"");
	assert(makePage!(m, testDispatcher, "name", "client/*", string) ().url("hello") == Conf.urlBase~"client/hello");
	assert(makePage!(m, testDispatcher, "name", "client/:foo", int) ().url(5)       == Conf.urlBase~"client/5");
	assert(makePage!(m, testDispatcher, "name", "*", int)           ().url(5)       == Conf.urlBase~"5");
}
