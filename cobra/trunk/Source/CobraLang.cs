using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;


namespace Cobra.Lang {


static public class CobraCore {

	static public Version Version {
		get {
			return new Version(0, 2, 0);
		}
	}

	static public int ReleaseNum {
		get {
			return 15;  // increment by exactly one with each release, no matter how big or small
		}
	}

	static public List<string> CommandLineArgs {
		get {
			return new List<string>(Environment.GetCommandLineArgs());
		}
	}

	static public bool HasSuperStackTrace {
		get {
			return CobraImp.HasSuperStackTrace;
		}
	}

	static public void DumpStack() {
		CobraImp.DumpStack();
	}

	static public void DumpStack(TextWriter tw) {
		CobraImp.DumpStack(tw);
	}

	static public string ToTechString(object x) {
		if (x==null)
			return "nil";
		if (x is bool)
			return (bool)x ? "true" : "false";
		if (x is string) {
			string s = (string)x;
			s = s.Replace("\n", "\\n");
			s = s.Replace("\r", "\\r");
			s = s.Replace("\t", "\\t");
			s = "'" + s + "'";  // TODO: could be more sophisticated with respect to ' and "
			return s;
		}
		if (x is System.Collections.IList) {
			// TODO: should not go into infinite loop for circular references
			StringBuilder sb = new StringBuilder();
			sb.AppendFormat("{0}[", x.GetType().Name);
			string sep = "";
			foreach (object item in (System.Collections.IList)x) {
				sb.AppendFormat("{0}{1}", sep, ToTechString(item));
				sep = ", ";
			}
			sb.AppendFormat("]");
			return sb.ToString();
		}
		// TODO: IDictionary
		// TODO: For StringBuilder, return StringBuilder'aoeu'
		return x.ToString();
	}

}


public interface ICallable {
	// object Call(object[] args);
	object Call(object arg);
}


public interface ICount {
	int Count {
		get;
	}
}


public class AssertException : Exception {

	protected string _fileName;
	protected int    _lineNumber;
	protected string _conditionSource;
	protected object _info;

	public AssertException(string fileName, int lineNumber, string conditionSource, object info)
		: this(fileName, lineNumber, conditionSource, info, null) {
	}

	public AssertException(string fileName, int lineNumber, string conditionSource, object info, Exception innerExc)
		: base(FixUp(info), innerExc) {
		_fileName = fileName;
		_lineNumber = lineNumber;
		_conditionSource = conditionSource;
		_info = info;
	}

	public override string Message {
		get {
			return string.Format("location={0}:{1}, info={2}, source={3}",
				_fileName, _lineNumber, _info==null?"nil":_info, _conditionSource);
		}
	}

	public object Info {
		get {
			return _info;
		}
	}

	static protected string FixUp(object x) {
		if (x==null)
			return "";
		if (x is string)
			return (string)x;
		string s = null;
		try {
			s = x.ToString();
			if (s==null)
				s = "";
		} catch (Exception e) {
			s = "Exception: " + e.Message;
		}
		return s;
	}

}


public class RequireException : AssertException {

	public RequireException(string fileName, int lineNumber, string conditionSource, object info)
		: this(fileName, lineNumber, conditionSource, info, null) {
	}

	public RequireException(string fileName, int lineNumber, string conditionSource, object info, Exception innerExc)
		: base(fileName, lineNumber, conditionSource, info, innerExc) {
	}

}


public class EnsureException : AssertException {

	public EnsureException(string fileName, int lineNumber, string conditionSource, object info)
		: this(fileName, lineNumber, conditionSource, info, null) {
	}

	public EnsureException(string fileName, int lineNumber, string conditionSource, object info, Exception innerExc)
		: base(fileName, lineNumber, conditionSource, info, innerExc) {
	}

}


public class ExpectException : Exception {

	protected Type _expectedExceptionType;
	protected Exception _actualException;

	public ExpectException(Type expectedExceptionType, Exception actualException)
		: base() {
		_expectedExceptionType = expectedExceptionType;
		_actualException = actualException;
	}

	public ExpectException(Type expectedExceptionType, Exception actualException, Exception innerExc)
		: base(null, innerExc) {
		_expectedExceptionType = expectedExceptionType;
		_actualException = actualException;
	}

	public override string Message {
		get {
			StringBuilder sb = new StringBuilder();
			sb.AppendFormat("Expecting exception: {0}, but ", _expectedExceptionType.Name);
			if (_actualException==null)
				sb.Append("no exception was thrown.");
			else
				sb.AppendFormat("a different exception was thrown: {0}.", _actualException);
			return sb.ToString();
		}
	}

	public Type ExpectedExceptionType {
		get {
			return _expectedExceptionType;
		}
	}

	public Exception ActualException {
		get {
			return _actualException;
		}
	}

}


public class FallThroughException : Exception {

	protected object _info;

	public FallThroughException()
		: this(null) {
	}

	public FallThroughException(object info)
		: base() {
		_info = info;
	}

	public FallThroughException(object info, Exception innerExc)
		: base(null, innerExc) {
		_info = info;
	}

	public override string Message {
		get {
			return string.Format("info={0}", _info==null?"nil":_info);
		}
	}

	public object Info {
		get {
			return _info;
		}
	}

}


static public class CobraImp {

	// public to Cobra source

	// supports Cobra language features

	static CobraImp() {
		_printToStack = new Stack<TextWriter>();
		PushPrintTo(Console.Out);
	}

	static public new bool Equals(object a, object b) {
		// decimal is retarded
		if (a is decimal) {
			if (b is decimal)
				return (decimal)a == (decimal)b;
			else if (b is int)
				return (decimal)a == (int)b;
			// TODO: what about other kinds of ints?
		}
		// double is a little retarded too
		if (a is double) {
			if (b is double)
				return (double)a == (double)b;
			else if (b is int)
				return (double)a == (int)b;
		}
		// TODO: probably need to handle all aspects of numeric promotion!
		// Note: IConvertible might be a fast, though imperfect way, of homing in on primitive types (except that string also implements it).
		if (a is char && b is string)
			return Equals((char)a, (string)b);
		else if (a is string && b is char)
			return Equals((char)b, (string)a);

		// what we really want for objects that can handle it:
		return object.Equals(a, b);
	}

	static public bool Equals(char c, string s) {
		if (s==null)
			return false;
		if (s.Length==1 && c==s[0])
			return true;
		return new string(c, 1) == s;
	}

	static public bool NotEquals(object a, object b) {
		return !Equals(a, b);
	}

	static public bool In(string a, string b) {
		return b.Contains(a);
	}

	static public bool In(char a, string b) {
		return b.IndexOf(a)!=-1;
	}

	static public bool In<innerType>(innerType a, IList<innerType> b) {
		return b.Contains(a);
	}

	static public bool In<keyType,valueType>(keyType a, IDictionary<keyType,valueType> b) {
		return b.ContainsKey(a);
	}

	static public bool IsTrue(char c) {
		return c!='\0';
	}

	static public bool IsTrue(int i) {
		return i!=0;
	}

	static public bool IsTrue(decimal d) {
		return d!=0;
	}

	static public bool IsTrue(float f) {
		return f!=0;
	}

	static public bool IsTrue(double d) {
		return d!=0;
	}

	static public bool IsTrue(string s) {
		return s!=null && s.Length>0;
	}

	static public bool IsTrue(System.Collections.ICollection c) {
		// TODO: does System.Collections.Generics.ICollection inherit the non-generic ICollection?
		// TODO: if a C# file uses both System.Collections and System.Collections.Generics, then what does "ICollection" mean?
		return c!=null && c.Count>0;
	}

	static public bool IsTrue(object x) {
		if (x==null)
			return false;
		if (x is bool)
			return (bool)x;
		if (x.Equals(0))
			return false;
		string s = x as string;
		if (s!=null)
			return IsTrue(s);
		if (x is char)
			return (char)x!='\0';
		ICount c = x as ICount;
		if (c!=null)
			return c.Count>0;
		System.Collections.ICollection col = x as System.Collections.ICollection;
		if (col!=null)
			return IsTrue(col);
		// TODO: review definition I made for Boo and Power
		return true;
	}

	static public bool Is(object a, object b) {
		return object.ReferenceEquals(a, b);
	}

	static public bool IsNot(object a, object b) {
		return !object.ReferenceEquals(a, b);
	}

	static public bool Is(Enum a, Enum b) {
		return a.Equals(b);
		//return a==b;  this returns false when you would expect true!
	}

	static public object ToOrNil<T>(object x)
		where T : struct {
		// using this method ensures that x is only evaluated once in the generated C# code for
		// x to? type
		if (x is T || x is T?)
			return x;
		else
			return null;
	}

	static private Stack<TextWriter> _printToStack;

	static public void PushPrintTo(TextWriter tw) {
		_printToStack.Push(tw);
	}

	static public void PopPrintTo() {
		_printToStack.Pop();
	}

	static public void PrintLine() {
		_printToStack.Peek().WriteLine();
	}

	static public void PrintLine(string s) {
		_printToStack.Peek().WriteLine(s);
	}

	static public void PrintStop() {
	}

	static public void PrintStop(string s) {
		_printToStack.Peek().Write(s);
	}

	static public string MakeString(params string[] args) {
		StringBuilder sb = new StringBuilder();
		foreach (object arg in args)
			sb.Append(arg);
		return sb.ToString();
	}

	static public string ToString(object x) {
		if (x==null)
			return "nil";
		if (x is bool)
			return (bool)x ? "true" : "false";
		return x.ToString();
	}

	static public string ToString(object x, string format) {
		if (x==null)
			return "nil";
		if (x is bool)
			return (bool)x ? "true" : "false";
		// there's probably a better way to do this:
		format = "{0:" + format + "}";
		return string.Format(format, x);
	}

	static public List<innerType> MakeList<innerType>(Type listType, params innerType[] args) {
		return new List<innerType>(args);
	}

	static public Dictionary<keyType,valueType> MakeDict<keyType,valueType>(Type dictType, params object[] args) {
		Dictionary<keyType,valueType> d = new Dictionary<keyType,valueType>();
		for (int i=0; i<args.Length; i+=2)
			d.Add((keyType)args[i], (valueType)args[i+1]);
		return d;
	}


	/// Show test progress

	static private bool _showTestProgress = false;

	static public bool ShowTestProgress {
		get {
			return _showTestProgress;
		}
		set {
			_showTestProgress = value;
		}
	}

	static private TextWriter _testProgressWriter = null;

	static public TextWriter TestProgressWriter {
		get {
			return _testProgressWriter==null ? Console.Out : _testProgressWriter;
		}
		set {
			_testProgressWriter = value;
		}
	}

	static public void TestBegan(string className) {
		if (ShowTestProgress) {
			TestProgressWriter.WriteLine("Testing {0}...", className);
			TestProgressWriter.Flush();
		}
	}

	static public void TestEnded(string className) {
		if (ShowTestProgress) {
			TestProgressWriter.WriteLine("Completed testing of {0}.\n", className);
			TestProgressWriter.Flush();
		}
	}


	/// Super Stack Trace!

	static public bool HasSuperStackTrace {
		get {
			return _badStackCopy!=null;
		}
	}

	static private Stack<CobraFrame> _superStack = new Stack<CobraFrame>();
	static private Stack<CobraFrame> _badStackCopy = null;

	static public void PushFrame(string declClassName, string methodName, params object[] args) {
		_superStack.Push(new CobraFrame(declClassName, methodName, args));
	}

	static public void SetLine(int lineNum) {
		_superStack.Peek().SetLine(lineNum);
	}

	static public T SetLocal<T>(string name, T value) {
		_superStack.Peek().SetLocal(name, value);
		return value;
	}

	static public void CaughtUncaughtException() {
		if (_badStackCopy==null) {
			_badStackCopy = new Stack<CobraFrame>(_superStack.Count);
			foreach (CobraFrame frame in _superStack)
				_badStackCopy.Push(frame.Copy());
		}
	}

	static public void PopFrame() {
		_superStack.Pop();
	}

	static public void DumpStack() {
		DumpStack(Console.Out);
	}

	static public void DumpStack(TextWriter tw) {
		tw.WriteLine("Stack trace:");
		if (_badStackCopy==null)
			tw.WriteLine("No bad stack.");
		int i = 0;
		foreach (CobraFrame frame in _badStackCopy) {
			frame.Dump(tw, i);
			i++;
		}
	}

}

internal class CobraFrame {

	protected string _declClassName;
	protected string _methodName;
	protected int _lineNum;
	protected object[] _args;
	protected Dictionary<string, object> _locals;
	protected List<string> _localNamesInOrder;

	// args should have the arg names embedded: "x", x, "y", y
	public CobraFrame(string declClassName, string methodName, params object[] args) {
		_declClassName = declClassName;
		_methodName = methodName;
		_args = (object[])args.Clone();
		_locals = new Dictionary<string, object>();
		_localNamesInOrder = new List<string>();
		for (int j=0; j<_args.Length; j+=2)
			SetLocal((string)_args[j], _args[j+1]);
	}

	public void SetLine(int lineNum) {
		_lineNum = lineNum;
	}

	public void SetLocal(string name, object value) {
		if (!_locals.ContainsKey(name))
			_localNamesInOrder.Add(name);
		_locals[name] = value;
	}

	public void Dump(TextWriter tw, int i) {
		int nameWidth = 8;
		tw.WriteLine("\n    {0}. {1}", i, this);
		tw.WriteLine("        args");
		for (int j=0; j<_args.Length; j+=2) {
			tw.Write("               {0} = ", ((string)_args[j]).PadRight(nameWidth));
			string s;
			try {
				s = CobraCore.ToTechString(_args[j+1]);
			} catch (Exception e) {
				s = "ToString() Exception: " + e.Message;
			}
			tw.WriteLine(s);
		}
		tw.WriteLine("        locals");
		foreach (string name in _localNamesInOrder) {
			if (name=="this")
				continue;
			tw.Write("               {0} = ", name.PadRight(nameWidth));
			string s;
			try {
				s = CobraCore.ToTechString(_locals[name]);
			} catch (Exception e) {
				s = "ToString() Exception: " + e.Message;
			}
			tw.WriteLine(s);
		}
	}

	public override string ToString() {
		return string.Format("def {0}.{1} at line {2}", _declClassName, _methodName, _lineNum);
	}

	public CobraFrame Copy() {
		return (CobraFrame)MemberwiseClone();
	}

}

}
