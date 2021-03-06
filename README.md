SemiTwist Web Framework
=======================

A usable-but-unpolished Vibe.d/mustache-based web framework. This is a framework I've built up as part of my own (currently in-development) web projects, but I've separated it out for reusability. It provides an additional integrated feature-set on top of Vibe.d, such as:

* A class-based session system (based on Vibe.d's sessions):
  - Allows arbitrary data types and compile-time checking of key names.
  - Automatically creates/resumes a session on page requests.
  - Logged in sessions are persistently logged in via a MySQL backend (although other session data is not automatically persistent).

* Mustache-D templates.

* A page system which prevents internal broken links and populates Vibe.d's UrlRouter.

* A customizable form system which handles HTML-generation, validation, validation error messages and re-populating of form data on failed validation.

* Configurable prefix for URLs.

* Customizable HTTP handler struct which:
  - Prevents accidents like "headers already sent", sending a page twice, or forgetting to send a response on certain code paths. This is because your handler *returns* its page as a return value instead of manually writing it.
  - Automatically provides access to the request, response, session and Mustache view context without a non-DRY argument list repeated for every handler.

* Automatically log uncaught exceptions, and optionally (for debugging) all MySQL commands.

* Various command-line options, such as listening IP/port, logfile, (dis)allowing of insecure access, and whether or not to display exceptions and stack traces on the "500 - Internal error" page.

* Direct access to Vibe.d is completely allowed. You can have purely Vibe.d-only pages side-by-side with ones that use SemiTwist Web Framework.

* Various helper functions.

The current downsides are:
* The API isn't stable, well-polished or documented.
* Setting up a new project using it currently involves some manual effort (see below).
* Compared to Vibe.d itself, not quite as much as attention has been paid to avoiding GC allocations.

How to Set Up a New Project
---------------------------

To set up a new project using SemiTwist Web Framework:

1. Create a new directory for your project.

2. In your new project's directory, create a basic [```dub.json```/```dub.sdl``` DUB project file](http://code.dlang.org/package-format) that lists ```semitwistweb``` as a dependency (as [demonstrated here](http://code.dlang.org/packages/semitwistweb)).

3. From your new project's directory, run ```dub upgrade``` to download all your project's dependencies, including SemiTwistWeb. This will also copy two directories from SemiTwistWeb to your project: ```res``` and ```www-static```.

4. Make a copy of ```res/conf-sample.d``` named ```res/conf.d```. Open the new ```res/conf.d```, read the comments and enter your own configuration settings.

5. Open ```res/dbTroubleshootMsg.txt``` and read it. Make sure you have a MySQL database set up appropriately as that file describes.

6. Open ```res/init.sql```. Leave the ```session``` table alone, but add any additional SQL statements to initialize your own MySQL database.

7. Customize the main HTML page template ```res/templates/frame-main.html``` (using Mustache syntax), the CSS file ```www-static/style.css``` (not a templated file), and optionally the HTML error page templates (```res/templates/err-*.html```) to your liking.

8. Import Vibe.d by using ```import vibe.vibe;```, NOT ```import vibe.d;```. Also import (at the very least) ```semitwistWeb.init```. Then create a ```main()``` function like this:

	```
	module myProj.main;

	import vibe.vibe;
	import mysql.db;
	import semitwistWeb.init;
	//...whatever other imports...

	int main(string[] args)
	{
		//...any initial setup here...
		return semitwistWebMain!(MyCustomSessionType, MyCustomHandlerType, MyCustomDBOTypes)(args, &postInit, () => openDB());
	}

	/// Returns: -1 normally, or else an errorlevel
	/// for the program to immediately exit with.
	int postInit(ref HttpServerSettings httpServerSettings, ref UrlRouter router)
	{
		/+
		...any additional setup to be done after semitwistWeb
		initializes, but just before it starts listening for
		connections...
		+/
		
		return -1;
	}

	Connection openDB()
	{
		//...open a connection to your MySQL DB...
	}
	```

9. Add a root index page and other pages to your site using the completely undocumented API. Also, there aren't any example applications to learn from yet. Yea, I'm really helpful so far aren't I?

10. Build your project.

11. Run your project with the --init-db switch to create the needed DB tables (THIS WILL DESTROY ALL DATA!)

12. Run your project without the --init-db switch to actually start it.

What is "SemiTwist"?
--------------------

This project is "SemiTwist Web Framework" or "SemiTwist Web". "SemiTwist" is just an umbrella name I attach to some of my projects so their names aren't too generic, like "My Web Framework". It's also my domain name: semitwist.com.
