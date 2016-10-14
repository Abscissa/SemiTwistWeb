/// Written in the D programming language.

module semitwistWeb.handler;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.range;
import std.regex;
import std.stdio;
import std.string;
import std.traits;
import std.typecons;
import std.variant;

import vibe.vibe;
import mysql.db;
import semitwist.util.all;

import semitwistWeb.conf;
import semitwistWeb.db;
import semitwistWeb.doc;
import semitwistWeb.session;
import semitwistWeb.util;

template handlerDispatch(CustomHandler)
{
	void handlerDispatch(string funcName)(HTTPServerRequest req, HTTPServerResponse res)
	{
		PageBase.validateLoginPageName();

		if(CustomHandler.noCache)
			CustomHandler.clearDocsCache();
		
		// Force HTTPS
		if(!CustomHandler.allowInsecure && !req.isSSLReverseProxy())
		{
			if(!conf.host.toLower().startsWith("https://"))
				throw new Exception("Internal Error: conf.host was expected to always be https whenever SSL is being forced!");

			string url;
			if(req.queryString == "")
				url = text(conf.host, req.path);
			else
				url = text(conf.host, req.path, "?", req.queryString);

			auto page = CustomHandler(BaseHandler(req, res, null), null).redirect(url, HTTPStatus.TemporaryRedirect);
			page.send(req, res, null);
			return;
		}

		auto sess = CustomHandler.setupSession(req, res);

		// Instantiate viewContext on the stack, it doesn't need to outlive this function.
		mixin(createUnsafeScoped("Mustache.Context", "viewContext"));

		auto handler = CustomHandler(BaseHandler(req, res, sess, viewContext), sess);
		mixin("handler."~funcName~"().send(req, res, sess);");
	}
}

template handlerDispatchError(CustomHandler)
{
	void handlerDispatchError(string funcName)(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error)
	{
		if(CustomHandler.noCache)
			CustomHandler.clearDocsCache();

		auto sess = CustomHandler.setupSession(req, res);

		// Instantiate viewContext on the stack, it doesn't need to outlive this function.
		mixin(createUnsafeScoped("Mustache.Context", "viewContext"));
		
		auto handler = CustomHandler(BaseHandler(req, res, sess, viewContext), sess);
		mixin("handler."~funcName~"(error).send(req, res, sess);");
	}
}

struct HttpResult
{
	int statusCode;
	string mime;
	Algebraic!(string, const(ubyte)[]) content;
	string locationHeader;
	
	void send(HTTPServerRequest req, HTTPServerResponse res, SessionData sess)
	{
		sendImpl(req, res, sess, true);
	}

	private void sendImpl(
		HTTPServerRequest req, HTTPServerResponse res,
		SessionData sess, bool normalErrorPageOnFailure
	)
	{
		void fail()
		{
			if(normalErrorPageOnFailure)
			{
				// Attempt to send the normal 500 page
				BaseHandler(req, res, sess)
					.genericError(500)
					.sendImpl(req, res, sess, false);
			}
			else
			{
				// Just send a bare-bones 500 page
				sess.oneShotMessage = null;
				res.statusCode = 500;
				res.writeBody(BaseHandler.genericErrorMessage, "text/html");
			}
		}
		
		void setupHeaders()
		{
			res.statusCode = statusCode;
			if(locationHeader != "")
				res.headers["Location"] = locationHeader;
		}
		
		void clearOneShotMessage()
		{
			// If statusCode is 2xx, 4xx or 5xx
			if((statusCode >= 200 && statusCode < 300) || statusCode >= 400)
				sess.oneShotMessage = null;
		}
		
		if(!content.hasValue)
		{
			stLogError("HttpResult.content has no value. URL: ", req.path);
			fail();
		}
		else if(content.type == typeid(string))
		{
			setupHeaders();
			clearOneShotMessage();
			res.writeBody(content.get!(string)(), mime);
		}
		else if(content.type == typeid( const(ubyte)[] ))
		{
			setupHeaders();
			clearOneShotMessage();
			res.writeBody(content.get!( const(ubyte)[] )(), mime);
		}
		else
		{
			stLogError("HttpResult.content contains an unexpected type");
			fail();
		}
	}
}

struct BaseHandler
{
	enum genericErrorMessage = "<p>Sorry, an error has occurred.</p>";

	static bool noCache         = false;
	static bool allowInsecure   = false;
	static bool publicDebugInfo = false;
	static void function(Mustache.Context, SessionData) addAppContextCallback;
	HTTPServerRequest req;
	HTTPServerResponse res;
	SessionData baseSess;
	Mustache.Context viewContext;  /// On the stack: DO NOT SAVE past lifetime of handlerDispatch.

	HttpResult errorHandler(HTTPServerErrorInfo error)
	{
		try
		{
			if(error.code >= 400 && error.code < 500)
				return errorHandler4xx(error);

			if(error.code >= 500 && error.code < 600)
				return errorHandler5xx(error);
			
			logHttpError(error);
			stLogWarn(
				format(
					"[%s] Unexpectedly handled \"error\" code outside 4xx/5xx: %s - %s. Sending 500 instead.",
					req.clientIPs, error.code, httpStatusText(error.code)
				)
			);
			
			return genericError(HTTPStatus.InternalServerError);
		}
		catch(Exception e)
		{
			stLogError("Uncaught exception during error handler: ", e);

			// Just send a bare-bones 500 page
			HttpResult r;
			r.statusCode = 500;
			r.mime = "text/html";
			r.content = BaseHandler.genericErrorMessage;
			return r;
		}
	}

	private void logHttpError(HTTPServerErrorInfo error)
	{
		stLogError(
			format(
				"[%s] %s - %s\n\n%s\n\nInternal error information:\n%s",
				req.clientIPs, error.code, httpStatusText(error.code),
				error.message, error.debugMessage
			)
		);
	}

	private HttpResult errorHandler4xx(HTTPServerErrorInfo error)
	{
		if(error.code == 400)
			return badRequest();

		if(error.code == 404)
			return notFound();

		return genericError(error.code);
	}
	
	private HttpResult errorHandler5xx(HTTPServerErrorInfo error)
	{
		logHttpError(error);

		if(BaseHandler.publicDebugInfo)
		{
			auto errorMsg =
				BaseHandler.genericErrorMessage ~
				`<pre class="pre-wrap" style="width: 100%;">` ~
				htmlEscapeMin(error.debugMessage) ~
				"</pre>";

			return genericError(error.code, errorMsg);
		}
		else
			return genericError(error.code);
	}
	
	HttpResult genericError(int statusCode)
	{
		return genericError(statusCode, BaseHandler.genericErrorMessage);
	}
	
	HttpResult genericError(int statusCode, string message)
	{
		viewContext["errorCode"]   = to!string(statusCode);
		viewContext["errorString"] = httpStatusText(statusCode);
		viewContext["errorMsg"]    = message;

		HttpResult r;
		r.statusCode = statusCode;
		r.mime = "text/html";
		r.content = renderPage("err-generic");
		return r;
	}
	
	HttpResult notFound()
	{
		HttpResult r;
		r.statusCode = HTTPStatus.NotFound;
		r.mime = "text/html";
		r.content = renderPage("err-not-found");
		return r;
	}

	HttpResult redirect(string url, int status = HTTPStatus.Found)
	{
		HttpResult r;
		r.statusCode = status;
		r.locationHeader = url;
		r.mime = "text/plain";
		r.content = "Redirect to: " ~ url;
		return r;
	}
	
	/// Automatically sets session's postLoginUrl to the URL requested by the user.
	HttpResult redirectToLogin(string loginUrl)
	{
		baseSess.postLoginUrl = req.requestURL;
		return redirect(loginUrl);
	}
	
	/// If postLoginUrl=="", that signals that your app's default
	/// after-login URL is to be used.
	HttpResult redirectToLogin(string loginUrl, string postLoginUrl)
	{
		baseSess.postLoginUrl = postLoginUrl;
		return redirect(loginUrl);
	}
	
	/// Call this when the user succesfulyl logs in.
	///
	/// If the user had attempted to reach a login-only URL, this redirects
	/// them back to it. Otherwise, this redirects to 'defaultUrl'.
	HttpResult redirectToPostLogin(string defaultUrl)
	{
		auto targetUrl = baseSess.postLoginUrl;
		if(targetUrl == "")
			targetUrl = defaultUrl;
		
		baseSess.postLoginUrl = null;
		return redirect(targetUrl);
	}
	
	HttpResult badRequest()
	{
		HttpResult r;
		r.statusCode = HTTPStatus.BadRequest;
		r.mime = "text/html";
		r.content = renderPage("err-bad-request");
		return r;
	}
	
	HttpResult ok(T)(T content, string mimeType) if( is(T:string) || is(T:const(ubyte)[]) )
	{
		HttpResult r;
		r.statusCode = HTTPStatus.OK;
		r.mime = mimeType;
		r.content = content;
		return r;
	}
	
	HttpResult okHtml(PageBase page)
	{
		return okHtml(renderPage(page));
	}
	
	HttpResult okHtml(string content)
	{
		return ok(content, "text/html");
	}
	
	string renderPage(PageBase page)
	{
		return renderPage(page.viewName);
	}
	
	string renderPage(string templateName)
	{
		if(addAppContextCallback is null)
			throw new Exception("'BaseHandler.addAppContextCallback' has not been set.");
		
		addCommonContext(viewContext, baseSess);
		addAppContextCallback(viewContext, baseSess);
		return mustache.renderString(HtmlTemplateAccess[templateName], viewContext);
	}
}
