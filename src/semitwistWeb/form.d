/// Written in the D programming language.

module semitwistWeb.form;

import std.algorithm;
import std.array;
import std.conv;
import std.string;
import std.path : buildPath;

import arsd.dom;
import vibe.inet.webform;

import semitwist.util.all;
import semitwist.arsddom;

import mustacheLib = mustache;
alias mustacheLib.MustacheEngine!string Mustache;

void addFormContext(Mustache.Context c, FormSubmission[string] sessSubmissions, string[] formNames)
{
	foreach(formName; formNames)
		c.addFormContext(sessSubmissions, formName);
}

void addFormContext(Mustache.Context c, FormSubmission[string] sessSubmissions, string formName)
{
	auto submissionPtr = formName in sessSubmissions;
	if(!submissionPtr)
		throw new Exception(
			text("Form '", formName, "' can't be found in SessionData.submissions.")
		);
	
	HtmlForm.get(formName).addFormDataContext(c, *submissionPtr);
}

/// formToKeep: For example, if formToKeep is "purchase", then
///             submissions["purchase"] will not be cleared,
///             but the rest will.
///             If formsToKeep is null or empty string, then all will be cleared.
void clearOtherForms(FormSubmission[string] submissions, string currUrl, string formToKeep)
{
	// Validate formToKeep
	if(formToKeep != "" && formToKeep !in submissions)
		throw new Exception(text("Form name '", formToKeep, "' doesn't exist in submissions."));
	
	// Clear all except formToKeep
	foreach(name, val; submissions)
	if(name != formToKeep || submissions[name].url != currUrl)
		submissions[name].clear();
}

/// formsToKeep: For example, if formsToKeep is ["purchase", "foobar"],
///              then submissions["purchase"] and submissions["foobar"]
///              will not be cleared, but the rest will.
///              If formsToKeep is empty, then all will be cleared.
void clearOtherForms(FormSubmission[string] submissions, string currUrl, string[] formsToKeep)
{
	// Validate formsToKeep
	foreach(name; formsToKeep)
	if(name !in submissions)
		throw new Exception(text("Form name '", name, "' doesn't exist in submissions."));
	
	// Clear all except formsToKeep
	foreach(name, val; submissions)
	if(!formsToKeep.contains(name) || submissions[name].url != currUrl)
		submissions[name].clear();
}

enum FormElementType
{
	Text,
	TextArea,
	Password,
	Button,
	ErrorLabel,
}

enum FormElementOptional
{
	No,	Yes
}

struct FormElement
{
	FormElementType type;

	private string _name;
	@property string name() { return _name; }

	string label;
	string defaultValue;
	string confirmationOf;
	
	private FormElementOptional _isOptional = FormElementOptional.No;
	@property FormElementOptional isOptional()
	{
		return _isOptional;
	}
	@property void isOptional(FormElementOptional value)
	{
		if(type == FormElementType.Button || type == FormElementType.ErrorLabel)
			_isOptional = FormElementOptional.Yes;
		else
			_isOptional = value;
	}
	
	private string _mustacheTagValue;
	@property string mustacheTagValue()
	{
		if(!_mustacheTagValue)
			_mustacheTagValue = name ~ "-value";

		return _mustacheTagValue;
	}
	
	private string _mustacheTagExtraClass;
	@property string mustacheTagExtraClass()
	{
		if(!_mustacheTagExtraClass)
			_mustacheTagExtraClass = name ~ "-extra-class";

		return _mustacheTagExtraClass;
	}
	
	this(
		FormElementType type, string name, string label,
		string defaultValue = "", string confirmationOf = "",
		FormElementOptional isOptional = FormElementOptional.No
	)
	{
		this.type           = type;
		this._name          = name;
		this.label          = label;
		this.defaultValue   = defaultValue;
		this.confirmationOf = confirmationOf;
		this.isOptional     = isOptional;
	}
	
	//TODO: Support radios and checkboxes
	static FormElement fromDom(Element inputElem, Form form, string filename="")
	{
		auto formId = requireAttribute(form, "id")[HtmlForm.formIdPrefix.length..$];
		auto isInputTag    = inputElem.tagName.toLower() == "input";
		auto isTextAreaTag = inputElem.tagName.toLower() == "textarea";
		auto isErrorLabel  = inputElem.tagName.toLower() == "validate-error";
		
		if(isErrorLabel)
		{
			foreach(ref labelTextElem; inputElem.getElementsByTagName("label-text"))
				labelTextElem.outerHTML = "{{{form-"~formId~"-errorMsg}}}";
			
			inputElem.outerHTML =
				"{{#form-"~formId~"-hasErrorMsg}}" ~
				inputElem.innerHTML ~
				"{{/form-"~formId~"-hasErrorMsg}}";

			return FormElement(FormElementType.ErrorLabel, "input-errorlabel", "");
		}
		
		if(!isInputTag && !isTextAreaTag)
		{
			throw new Exception(
				"Unknown type of input element (tagName: '"~inputElem.tagName~
				"') on form '"~formId~"' in file '"~
				(filename==""?"{unknown}":filename)~"'"
			);
		}
		
		// Id
		auto inputId = requireAttribute(inputElem, "id");
		inputElem.setAttribute("name", inputId);
		
		// Type of input
		FormElementType inputType = FormElementType.TextArea;
		if(!isTextAreaTag)
		{
			auto typeName = requireAttribute(inputElem, "type");
			switch(typeName)
			{
			case "text":     inputType = FormElementType.Text;     break;
			case "password": inputType = FormElementType.Password; break;
			case "submit":   inputType = FormElementType.Button;   break;
			default:
				throw new Exception("Unknown value on <input>'s type attribute: '"~typeName~"'");
			}
		}
		
		// Label
		string labelText;
		if(inputType == FormElementType.Button)
			labelText = inputElem.getAttribute("label-text");
		else
			labelText = requireAttribute(inputElem, "label-text");

		auto labelElem = form.getLabel(inputId);
		if(!labelElem && inputType != FormElementType.Button)
			throw new Exception("Missing <label> with 'for' attribute of '"~inputId~"' (in template '"~filename~"')");

		if(labelElem)
		foreach(ref labelTextElem; labelElem.getElementsByTagName("label-text"))
			labelTextElem.outerHTML = labelText;

		inputElem.removeAttribute("label-text");
		
		// Confirmation of...
		string confirmationOf = null;
		if(inputElem.hasAttribute("confirms"))
		{
			confirmationOf = inputElem.getAttribute("confirms");
			inputElem.removeAttribute("confirms");
		}
		
		// Is optional?
		auto isOptional = FormElementOptional.No;
		if(inputElem.hasAttribute("optional"))
		{
			isOptional = FormElementOptional.Yes;
			inputElem.removeAttribute("optional");
		}
		
		// Default value
		auto defaultValue = form.getValue(inputId);
		if(inputType != FormElementType.Button)
		{
			//TODO: This will need to be different for radio/checkbox:
			form.setValue(inputId, "{{"~inputId~"-value}}");
		}

		// Validate error class
		if(labelElem)
		{
			inputElem.addClass("{{"~inputId~"-extra-class}}");
			labelElem.addClass("{{"~inputId~"-extra-class}}");
		}
		
		// Create element
		return FormElement(
			inputType, inputId, labelText,
			defaultValue, confirmationOf, isOptional
		);
	}

	bool isCompatible(FormElement other)
	{
		// Ignore 'label' and 'defaultValue'
		return
			this.type == other.type &&
			this.name == other.name &&
			this.confirmationOf == other.confirmationOf &&
			this.isOptional == other.isOptional;
	}
}

string makeErrorMessage(FormSubmission submission)
{
	static string validateErrorFieldNameSpan(string name)
	{
		return `<span class="validate-error-field-name">`~name~"</span>";
	}

	// Collect all errors found
	FieldError errors = FieldError.None;
	foreach(fieldName, err; submission.invalidFields)
		errors |= err;
	
	// Add a "missing field(s)" message if needed
	string[] errMsgs;
	if(errors & FieldError.Missing)
	{
		if(submission.missingFields.length == 1)
			errMsgs ~=
				"The required field "~
				validateErrorFieldNameSpan(submission.missingFields[0].label)~
				" is missing.";
		else
		{
			string invalidLabels;
			foreach(invalidElem; submission.missingFields)
			{
				if(invalidLabels != "")
					invalidLabels ~= ", ";
				invalidLabels ~= validateErrorFieldNameSpan(invalidElem.label);
			}
			errMsgs ~= "These required fields are missing: "~invalidLabels;
		}
	}

	// Add "confirmation failed" messages if needed
	if(errors & FieldError.ConfirmationFailed)
	foreach(invalidElem; submission.confirmationFailedFields)
		errMsgs ~=
			"The "~
			validateErrorFieldNameSpan(submission.form[invalidElem.confirmationOf].label)~
			" and "~
			validateErrorFieldNameSpan(invalidElem.label)~
			" fields don't match.";
	
	// Combine all error messages
	string comboErrMsg;
	if(errMsgs.length == 1)
		comboErrMsg = "<span>"~errMsgs[0]~"</span>";
	else
	{
		comboErrMsg = "<span>Please fix the following:</span><ul>";
		foreach(msg; errMsgs)
			comboErrMsg ~= "<li>"~msg~"</li>";
		comboErrMsg ~= "</ul>";
	}

	return comboErrMsg;
}

enum FieldError
{
	None               = 0,
	Missing            = 0b0000_0000_0001,
	ConfirmationFailed = 0b0000_0000_0010,
	Custom1            = 0b0001_0000_0000,  // App-specific error
	Custom2            = 0b0010_0000_0000,  // App-specific error
	Custom3            = 0b0100_0000_0000,  // App-specific error
	Custom4            = 0b1000_0000_0000,  // App-specific error
}

final class FormSubmission
{
	HtmlForm form;
	
	this()
	{
		clear();
	}
	
	private bool _isValid;
	@property bool isValid() { return _isValid; }
	@property void isValid(bool value)
	{
		_isValid = value;

		if(_isValid)
			_errorMsg = "";
		else if(_errorMsg == "")
			_errorMsg = "A problem occurred, please try again later.";
	}

	string             url;
	FormFields         fields;        // Indexed by form element name
	FieldError[string] invalidFields; // Indexed by form element name
	FormElement[]      missingFields;
	FormElement[]      confirmationFailedFields;
	
	private string _errorMsg;
	@property string errorMsg() { return _errorMsg; }
	@property void errorMsg(string value)
	{
		_errorMsg = value;
		_isValid = value == "";
	}

	void clear()
	{
		isValid   = true;
		_errorMsg = null;

		fields        = FormFields();
		url           = null;
		missingFields = null;
		invalidFields = null;
		confirmationFailedFields = null;
	}

	void setFieldError(string name, FieldError err)
	{
		setFieldError(form[name], err);
	}
	
	void setFieldError(FormElement formElem, FieldError err)
	{
		void setInvalidField(string _name, FieldError _err)
		{
			isValid = false;

			if(_name in invalidFields)
				invalidFields[_name] |= _err;
			else
				invalidFields[_name] = _err;
		}
		
		auto name = formElem.name;
		
		if(err & FieldError.Missing && !hasError(name, FieldError.Missing))
			missingFields ~= formElem;
		
		if(err & FieldError.ConfirmationFailed && !hasError(name, FieldError.ConfirmationFailed))
		{
			confirmationFailedFields ~= formElem;
			
			auto currElem = formElem;
			while(currElem.confirmationOf != "")
			{
				currElem = form[currElem.confirmationOf];
				setInvalidField(currElem.name, FieldError.ConfirmationFailed);
			}
		}

		setInvalidField(name, err);
	}
	
	bool hasError(string name, FieldError err)
	{
		if(auto errPtr = name in invalidFields)
		if(*errPtr & err)
			return true;
		
		return false;
	}
}

/// Handles null safely and correctly
@property bool isClear(FormSubmission submission)
{
	if(!submission)
		return true;
	
	return submission.fields.length == 0 && submission.isValid;
}

// Just to help avoid excess reallocations.
private FormSubmission _blankFormSubmission;
private @property FormSubmission blankFormSubmission()
{
	if(!_blankFormSubmission)
		_blankFormSubmission = new FormSubmission();
	
	return _blankFormSubmission;
}

struct HtmlForm
{
	static enum formIdPrefix = "form-";

	private string _name;
	@property string name() { return _name; }

	string origFilename;
	
	private string _mustacheTagHasErrorMsg;
	@property string mustacheTagHasErrorMsg()
	{
		if(!_mustacheTagHasErrorMsg)
			_mustacheTagHasErrorMsg = "form-"~name~"-hasErrorMsg";

		return _mustacheTagHasErrorMsg;
	}
	
	private string _mustacheTagErrorMsg;
	@property string mustacheTagErrorMsg()
	{
		if(!_mustacheTagErrorMsg)
			_mustacheTagErrorMsg = "form-"~name~"-errorMsg";

		return _mustacheTagErrorMsg;
	}

	private FormElement[] elements;
	private FormElement[string] elementLookup;

	this(string name, string origFilename, FormElement[] elements)
	{
		this._name = name.strip();
		this.origFilename = origFilename;
		this.elements = elements;

		validateElements();
		
		FormElement[string] lookup;
		foreach(elem; elements)
			lookup[elem.name] = elem;
		elementLookup = lookup.dup;
	}

	private static HtmlForm[string] registeredForms;
	static HtmlForm get(string formName)
	{
		return registeredForms[formName];
	}
	
	private static string[] registeredFormNames;
	private static bool registeredFormNamesInited = false;
	static string[] getNames()
	{
		if(!registeredFormNamesInited)
		{
			registeredFormNames = registeredForms.keys;
			registeredFormNamesInited = true;
		}
		
		return registeredFormNames;
	}
	
	static FormSubmission[string] newSessionData()
	{
		FormSubmission[string] submissions;

		foreach(name; HtmlForm.getNames())
			submissions[name] = new FormSubmission();
		
		return submissions;
	}
	
	/// Returns: Same HtmlForm provided, for convenience.
	static HtmlForm register(HtmlForm form)
	{
		if(form.name in registeredForms)
			throw new Exception(text("A form named '", form.name, "' is already registered."));
		
		registeredForms[form.name] = form;
		registeredFormNames = null;
		registeredFormNamesInited = false;
		return form;
	}
	
	/// Returns: Processed template html
	static string registerFromTemplate(string filename, string rawHtml, bool overwriteExisting=false)
	{
		//TODO: Somehow fix this "Temporarily escape mustache partials" so it works with alternate delimeters

		// Temporarily escape mustache partials start so DOM doesn't destroy it
		rawHtml = rawHtml.replace("{{>", "{{MUSTACHE-GT");
		// The <div> is needed so the DOM doesn't strip out leading/trailing mustache tags.
		rawHtml = "<div>"~rawHtml~"</div>";
		
		auto doc = new Document(rawHtml, true, true);
		foreach(form; doc.forms)
		if(form.hasClass("managed-form"))
			registerForm(form, filename, overwriteExisting);
		
		// Unescape mustache partials start so mustache can read it
		auto bakedHtml = doc.toString().replace("{{MUSTACHE-GT", "{{>");
		return bakedHtml;
	}
	
	static void registerForm(Form form, string filename, bool overwriteExisting=false)
	{
		// Generate the new HtmlForm's elements from HTML DOM (and adjust the DOM as needed)
		string formId;
		FormElement[] formElems;
		try
		{
			// Form ID
			formId = requireAttribute(form, "id");
			if(!formId.startsWith(formIdPrefix) || formId.length <= formIdPrefix.length)
				throw new Exception("Form id '"~formId~"' doesn't start with required prefix '"~formIdPrefix~"'");
			formId = formId[formIdPrefix.length..$];
			form.setAttribute("name", formId);

			// Form Elements
			foreach(elem; form.getElementsByTagName("input"))
				formElems ~= FormElement.fromDom(elem, form, filename);

			foreach(elem; form.getElementsByTagName("textarea"))
				formElems ~= FormElement.fromDom(elem, form, filename);

			foreach(elem; form.getElementsByTagName("validate-error"))
				formElems ~= FormElement.fromDom(elem, form, filename);
		}
		catch(MissingHtmlAttributeException e)
		{
			e.setTo(e.elem, e.attrName, filename);
			throw e;
		}
		
		// Register new HtmlForm, if necessary
		auto newHtmlForm = HtmlForm(formId, filename, formElems);
		if(isRegistered(formId))
		{
			auto oldHtmlForm = HtmlForm.get(formId);
			if(overwriteExisting)
			{
				oldHtmlForm.unregister();
				HtmlForm.register(newHtmlForm);
			}
			else if(!newHtmlForm.isCompatible(oldHtmlForm))
				throw new Exception("Redefinition of form '"~formId~"' in '"~filename~"' is incompatible with existing definition in '"~oldHtmlForm.origFilename~"'");
		}
		else
			HtmlForm.register(newHtmlForm);
	}
	
	static bool isRegistered(string formName)
	{
		return !!(formName in registeredForms);
	}

	bool isRegistered()
	{
		return
			name in registeredForms && this == registeredForms[name];
	}

	void unregister()
	{
		if(!isRegistered())
		{
			if(name in registeredForms)
				throw new Exception(text("Cannot unregister form '", name, "' because it's unequal to the registered form of the same name."));
			else
				throw new Exception(text("Cannot unregister form '", name, "' because it's not registered."));
		}
		
		registeredForms.remove(name);
		registeredFormNames = null;
		registeredFormNamesInited = false;
	}
	
	FormElement opIndex(string name)
	{
		return elementLookup[name];
	}
	
	FormElement* opBinaryRight(string op)(string name) if(op == "in")
	{
		return name in elementLookup;
	}
	
	bool isCompatible(HtmlForm other)
	{
		if(this.name != other.name)
			return false;
		
		if(this.elements.length != other.elements.length)
			return false;
		
		//TODO: Don't require elements to be in the same order
		foreach(i; 0..this.elements.length)
		if(!this.elements[i].isCompatible( other.elements[i] ))
			return false;
		
		return true;
	}
	
	void addFormDataContext(Mustache.Context c)
	{
		addFormDataContextImpl(c, false, blankFormSubmission);
	}
	
	void addFormDataContext(Mustache.Context c, FormSubmission submission)
	{
		addFormDataContextImpl(c, true, submission);
	}
	
	private void addFormDataContextImpl(Mustache.Context c, bool useSubmission, FormSubmission submission)
	{
		foreach(elem; elements)
		{
			final switch(elem.type)
			{
			case FormElementType.Text:
			case FormElementType.TextArea:
			case FormElementType.Password:
				string value = "";
				if(useSubmission && elem.name in submission.fields && submission.fields[elem.name] != "")
					value = submission.fields[elem.name];

				auto errorCode = submission.invalidFields.get(elem.name, FieldError.None);
				auto hasError = errorCode != FieldError.None;

				c[elem.mustacheTagValue] = value;
				c[elem.mustacheTagExtraClass] = hasError? "validate-error" : "";
				break;

			case FormElementType.Button:
				// Do nothing
				break;

			case FormElementType.ErrorLabel:
				if(useSubmission && submission.errorMsg != "")
				{
					c.useSection(submission.form.mustacheTagHasErrorMsg);
					c[submission.form.mustacheTagErrorMsg] = submission.errorMsg;
				}
				break;
			}
		}
	}

	///ditto
	FormSubmission process(
		FormSubmission submission, string url, FormFields data
	)
	{
		return partialProcess(submission, url, data, elements);
	}
	
	///ditto
	FormSubmission partialProcess(
		FormSubmission submission, string url, FormFields data, FormElement[] elementsToProcess
	)
	{
		submission.clear();
		submission.form = this;
		submission.url = url;
		
		// Get responses and check for required fields that are missing
		foreach(formElem; elementsToProcess)
		{
			bool valueExists = false;
			if(formElem.name in data)
			{
				auto value = data[formElem.name].strip();
				submission.fields[formElem.name] = value;
				if(value != "")
					valueExists = true;
			}
			
			if(!valueExists && formElem.isOptional == FormElementOptional.No)
				submission.setFieldError(formElem, FieldError.Missing);
		}
		
		// Check confirmation fields
		foreach(formElem; elementsToProcess)
		if(formElem.confirmationOf != "")
		{
			if(submission.fields[formElem.name] != submission.fields[formElem.confirmationOf])
				submission.setFieldError(formElem, FieldError.ConfirmationFailed);
		}
		
		// Did anything fail?
		if(!submission.isValid)
			submission.errorMsg = makeErrorMessage(submission);
		
		return submission;
	}
	
	private void validateElements()
	{
		void error(string msg)
		{
			throw new Exception(origFilename~" [form: '"~name~"']: "~msg);
		}
		
		bool buttonFound = false;
		bool errorLabelFound = false;
		foreach(elemIndex, elem; elements)
		{
			bool isConfirmationOfOk = elem.confirmationOf == "";

			foreach(elem2Index, elem2; elements)
			if(elemIndex != elem2Index)
			{
				if(elem.name == elem2.name.strip())
					error("Duplicate form element name: "~elem.name);
				
				if(elem.confirmationOf == elem2.name)
					isConfirmationOfOk = true;
			}
			
			if(elem.name == "")
				error("Form element name is empty");
			
			if(elem.name.endsWith("-label"))
				error(`Form element name cannot end with "-label"`);
			
			if(elem.name.endsWith("-value"))
				error(`Form element name cannot end with "-value"`);
			
			if(elem.name.endsWith("-extra-class"))
				error(`Form element name cannot end with "-extra-class"`);
			
			if(elem.confirmationOf == elem.name)
				error("Form element cannot be confirmationOf itself: "~elem.name);

			if(!isConfirmationOfOk)
				error("Form element '"~elem.name~"' is confirmationOf a non-existent element: "~elem.confirmationOf);

			if(elem.type == FormElementType.Button)
				buttonFound = true;

			if(elem.type == FormElementType.ErrorLabel)
				errorLabelFound = true;
		}
		
		if(!buttonFound)
			error("No Button element on form");

		if(!errorLabelFound)
			error("No ErrorLabel element on form");
	}
}
