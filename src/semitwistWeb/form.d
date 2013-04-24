/// Written in the D programming language.

module semitwistWeb.form;

import std.algorithm;
import std.conv;
import std.string;

import arsd.dom;
import semitwist.util.all;
import semitwistWeb.session;

enum FormElementType
{
	Text,
	TextArea,
	Password,
	Button,
	ErrorLabel,
	Label,
	Raw,
}

enum FormElementOptional
{
	No,	Yes
}

struct FormElement
{
	FormElementType type;
	string name;
	string label;
	string defaultValue;
	string[string] attributes;
	string confirmationOf;
	
	private FormElementOptional _isOptional = FormElementOptional.No;
	@property FormElementOptional isOptional()
	{
		return _isOptional;
	}
	@property void isOptional(FormElementOptional value)
	{
		if(
			type == FormElementType.Button ||
			type == FormElementType.ErrorLabel ||
			type == FormElementType.Label ||
			type == FormElementType.Raw
		)
		{
			_isOptional = FormElementOptional.Yes;
		}
		else
			_isOptional = value;
	}
	
	this(
		FormElementType type, string name, string label,
		string defaultValue = "", string[string] attributes = null,
		string confirmationOf = "",
		FormElementOptional isOptional = FormElementOptional.No
	)
	{
		this.type           = type;
		this.name           = name;
		this.label          = label;
		this.defaultValue   = defaultValue;
		this.attributes     = attributes;
		this.confirmationOf = confirmationOf;
		this.isOptional     = isOptional;
	}
}

alias
	string delegate(
		FormSubmission submission, FormElement formElem, string value, FieldError error
	)
	FormFormatterDg;

struct FormFormatter
{
	FormFormatterDg text;
	FormFormatterDg textArea;
	FormFormatterDg password;
	FormFormatterDg button;
	FormFormatterDg errorLabel;
	FormFormatterDg label;
	FormFormatterDg raw;
	
	string delegate(FormSubmission submission) makeErrorMessage;
}

void setAttributes(Element elem, string[string] attributes)
{
	if(attributes != null)
	{
		foreach(key, value; attributes)
		{
			if(key.toLower() == "class")
				elem.addClass(value);
			else if(key.toLower() == "style")
				elem.style ~= value;
			else
				elem.setAttribute(key, value);
		}
	}
}

string validateErrorFieldNameSpan(string name)
{
	return `<span class="validate-error-field-name">`~name~"</span>";
}

private FormFormatter _defaultFormFormatter;
private bool isDefaultFormFormatterInited = false;
@property FormFormatter defaultFormFormatter()
{
	if(!isDefaultFormFormatterInited)
	{
		string errorClass(FieldError error)
		{
			return error==FieldError.None? "" : ` class="validate-error"`;
		}

		string fieldLabel(FormElement formElem)
		{
			return formElem.isOptional? formElem.label~" (Optional)" : formElem.label;
		}
		
		string text(FormSubmission submission, FormElement formElem, string value, FieldError error)
		{
			auto label = fieldLabel(formElem);
			auto elem = Element.make("div", Html(`
				<tr>
					<td><label`~errorClass(error)~` id="`~formElem.name~`-label">`~label~`:</label></td>
					<td><input`~errorClass(error)~` value="`~value~`" type="text" id="`~formElem.name~`" name="`~formElem.name~`" /></td>
				</tr>
			`));

			auto input = elem.querySelector("input");
			setAttributes(input, formElem.attributes);
			return elem.innerHTML;
		}

		string textArea(FormSubmission submission, FormElement formElem, string value, FieldError error)
		{
			auto label = fieldLabel(formElem);
			auto elem = Element.make("div", Html(`
				<tr>
					<td><label`~errorClass(error)~` id="`~formElem.name~`-label">`~label~`:</label></td>
					<td><textarea`~errorClass(error)~` rows="3" cols="30" id="`~formElem.name~`" name="`~formElem.name~`">`~value~`</textarea></td>
				</tr>
			`));

			auto input = elem.querySelector("textarea");
			setAttributes(input, formElem.attributes);
			return elem.innerHTML;
		}

		string password(FormSubmission submission, FormElement formElem, string value, FieldError error)
		{
			auto label = fieldLabel(formElem);
			auto elem = Element.make("div", Html(`
				<tr>
					<td><label`~errorClass(error)~` id="`~formElem.name~`-label">`~label~`:</label></td>
					<td><input`~errorClass(error)~` value="" type="password" id="`~formElem.name~`" name="`~formElem.name~`" /></td>
				</tr>
			`));

			auto input = elem.querySelector("input");
			setAttributes(input, formElem.attributes);
			return elem.innerHTML;
		}

		string button(FormSubmission submission, FormElement formElem, string value, FieldError error)
		{
			auto elem = Element.make("div", Html(`
				<tr>
					<td colspan="2"><input value="`~formElem.label~`" type="submit" id="`~formElem.name~`" name="`~formElem.name~`" /></td>
				</tr>
			`));

			auto input = elem.querySelector("input");
			setAttributes(input, formElem.attributes);
			return elem.innerHTML;
		}

		string errorLabel(FormSubmission submission, FormElement formElem, string value, FieldError error)
		{
			if(value == "")
				return "";
			
			auto elem = Element.make("div", Html(`
				<tr>
					<td colspan="2"
						class="validate-error-msg" name="`~formElem.name~`" id="`~formElem.name~`"
					>`~value~`</td>
				</tr>
			`));

			auto input = elem.querySelector("td.validate-error-msg");
			setAttributes(input, formElem.attributes);
			return elem.innerHTML;
		}

		string label(FormSubmission submission, FormElement formElem, string value, FieldError error)
		{
			auto elem = Element.make("div", Html(`
				<tr>
					<td colspan="2" name="`~formElem.name~`" id="`~formElem.name~`">`~formElem.label~`</td>
				</tr>
			`));

			auto input = elem.querySelector("td."~formElem.name);
			setAttributes(input, formElem.attributes);
			return elem.innerHTML;
		}

		string raw(FormSubmission submission, FormElement formElem, string value, FieldError error)
		{
			return formElem.label;
		}

		string makeErrorMessage(FormSubmission submission)
		{
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

		_defaultFormFormatter.text       = &text;
		_defaultFormFormatter.textArea   = &textArea;
		_defaultFormFormatter.password   = &password;
		_defaultFormFormatter.button     = &button;
		_defaultFormFormatter.errorLabel = &errorLabel;
		_defaultFormFormatter.label      = &label;
		_defaultFormFormatter.raw        = &raw;
		_defaultFormFormatter.makeErrorMessage = &makeErrorMessage;

		isDefaultFormFormatterInited = true;
	}

	return _defaultFormFormatter;
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
	string[string]     fields;        // Indexed by form element name
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

		url           = null;
		fields        = null;
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
	
	return submission.fields is null && submission.isValid;
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
	string name;
	
	private FormElement[] elements;
	private FormElement[string] elementLookup;

	private string _selector;
	@property string selector()
	{
		return _selector;
	}

	this(string name, string selector, FormElement[] elements)
	{
		this.name = name;
		this._selector = selector;

		validateElements(elements);
		this.elements = elements;
		
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
	
	string toHtml(FormFormatter formatter = defaultFormFormatter)
	{
		return toHtmlImpl(false, blankFormSubmission, formatter);
	}
	
	string toHtml(FormSubmission submission, FormFormatter formatter = defaultFormFormatter)
	{
		return toHtmlImpl(true, submission, formatter);
	}
	
	private string toHtmlImpl(bool useSubmission, FormSubmission submission, FormFormatter formatter)
	{
		string html;
		foreach(elem; elements)
		{
			FormFormatterDg elemFormatter;
			final switch(elem.type)
			{
			case FormElementType.Text:
				elemFormatter = formatter.text is null?
					defaultFormFormatter.text : formatter.text;
				break;

			case FormElementType.TextArea:
				elemFormatter = formatter.textArea is null?
					defaultFormFormatter.textArea : formatter.textArea;
				break;

			case FormElementType.Password:
				elemFormatter = formatter.password is null?
					defaultFormFormatter.password : formatter.password;
				break;

			case FormElementType.Button:
				elemFormatter = formatter.button is null?
					defaultFormFormatter.button : formatter.button;
				break;

			case FormElementType.ErrorLabel:
				elemFormatter = formatter.errorLabel is null?
					defaultFormFormatter.errorLabel : formatter.errorLabel;
				break;

			case FormElementType.Label:
				elemFormatter = formatter.label is null?
					defaultFormFormatter.label : formatter.label;
				break;

			case FormElementType.Raw:
				elemFormatter = formatter.raw is null?
					defaultFormFormatter.raw : formatter.raw;
				break;
			}

			if(useSubmission && elem.type == FormElementType.ErrorLabel)
			{
				if(submission.errorMsg != "")
					html ~= elemFormatter(submission, elem, submission.errorMsg, FieldError.None);
			}
			else
			{
				string value = "";
				if(useSubmission && elem.name in submission.fields && submission.fields[elem.name] != "")
					value = submission.fields[elem.name];

				auto fieldError = submission.invalidFields.get(elem.name, FieldError.None);
				html ~= elemFormatter(submission, elem, value, fieldError);
			}
		}
		
		return html;
	}
	
	/// Returns: submission
	FormSubmission process(
		SessionData sess, string url, string[string] data,
		FormFormatter formatter = defaultFormFormatter
	)
	{
		return partialProcess(sess, url, data, elements, formatter);
	}
	
	///ditto
	FormSubmission partialProcess(
		SessionData sess, string url, string[string] data, FormElement[] elementsToProcess,
		FormFormatter formatter = defaultFormFormatter
	)
	{
		auto submission = sess.submissions[this.name];
		return partialProcess(submission, url, data, elementsToProcess, formatter);
	}

	///ditto
	FormSubmission process(
		FormSubmission submission, string url, string[string] data,
		FormFormatter formatter = defaultFormFormatter
	)
	{
		return partialProcess(submission, url, data, elements, formatter);
	}
	
	///ditto
	FormSubmission partialProcess(
		FormSubmission submission, string url, string[string] data, FormElement[] elementsToProcess,
		FormFormatter formatter = defaultFormFormatter
	)
	{
		submission.clear();
		submission.form = this;
		submission.url = url;
		
		// Get responses and check for required fields that are missing
		foreach(formElem; elementsToProcess)
		if(formElem.type != FormElementType.Label && formElem.type != FormElementType.Raw)
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
		{
			// Generate error message
			auto errorMessageMaker = formatter.makeErrorMessage is null?
				defaultFormFormatter.makeErrorMessage : formatter.makeErrorMessage;

			submission.errorMsg = errorMessageMaker(submission);
		}
		
		return submission;
	}
	
	private static void validateElements(FormElement[] elements)
	{
		bool buttonFound = false;
		bool errorLabelFound = false;
		foreach(elemIndex, elem; elements)
		{
			elem.name = elem.name.strip();

			bool isConfirmationOfOk = elem.confirmationOf == "";

			foreach(elem2Index, elem2; elements)
			if(elemIndex != elem2Index)
			{
				if(elem.name == elem2.name.strip())
					throw new Exception("Duplicate form element name: "~elem.name);
				
				if(elem.confirmationOf == elem2.name)
					isConfirmationOfOk = true;
			}
			
			if(elem.name == "")
				throw new Exception("Form element name is empty");
			
			if(elem.name.endsWith("-label"))
				throw new Exception(`Form element name cannot end with "-label"`);
			
			if(elem.confirmationOf == elem.name)
				throw new Exception("Form element cannot be confirmationOf itself: "~elem.name);

			if(!isConfirmationOfOk)
				throw new Exception("Form element '"~elem.name~"' is confirmationOf a non-existent element: "~elem.confirmationOf);

			if(elem.type == FormElementType.Button)
				buttonFound = true;

			if(elem.type == FormElementType.ErrorLabel)
				errorLabelFound = true;
		}
		
		if(!buttonFound)
			throw new Exception("No Button element on form");

		if(!errorLabelFound)
			throw new Exception("No ErrorLabel element on form");
			
	}
}
