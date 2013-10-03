// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of dart2js.js_emitter;

/**
 * Generates the code for all used classes in the program. Static fields (even
 * in classes) are ignored, since they can be treated as non-class elements.
 *
 * The code for the containing (used) methods must exist in the [:universe:].
 */
class CodeEmitterTask extends CompilerTask {
  final ContainerBuilder containerBuilder = new ContainerBuilder();
  bool needsDefineClass = false;
  bool needsMixinSupport = false;
  bool needsLazyInitializer = false;
  final Namer namer;
  ConstantEmitter constantEmitter;
  NativeEmitter nativeEmitter;
  CodeBuffer mainBuffer;
  final CodeBuffer deferredLibraries = new CodeBuffer();
  final CodeBuffer deferredConstants = new CodeBuffer();
  /** Shorter access to [isolatePropertiesName]. Both here in the code, as
      well as in the generated code. */
  String isolateProperties;
  String classesCollector;
  final Set<ClassElement> neededClasses = new Set<ClassElement>();
  final Set<ClassElement> rtiNeededClasses = new Set<ClassElement>();
  final List<ClassElement> regularClasses = <ClassElement>[];
  final List<ClassElement> deferredClasses = <ClassElement>[];
  final List<ClassElement> nativeClasses = <ClassElement>[];
  final List<Selector> trivialNsmHandlers = <Selector>[];
  final Map<String, String> mangledFieldNames = <String, String>{};
  final Map<String, String> mangledGlobalFieldNames = <String, String>{};
  final Set<String> recordedMangledNames = new Set<String>();
  final Set<String> interceptorInvocationNames = new Set<String>();

  /// A list of JS expressions that represent metadata, parameter names and
  /// type, and return types.
  final List<String> globalMetadata = [];

  /// A map used to canonicalize the entries of globalMetadata.
  final Map<String, int> globalMetadataMap = <String, int>{};

  // TODO(ngeoffray): remove this field.
  Set<ClassElement> instantiatedClasses;

  JavaScriptBackend get backend => compiler.backend;

  String get _ => space;
  String get space => compiler.enableMinification ? "" : " ";
  String get n => compiler.enableMinification ? "" : "\n";
  String get N => compiler.enableMinification ? "\n" : ";\n";

  /**
   * Raw ClassElement symbols occuring in is-checks and type assertions.  If the
   * program contains parameterized checks `x is Set<int>` and
   * `x is Set<String>` then the ClassElement `Set` will occur once in
   * [checkedClasses].
   */
  Set<ClassElement> checkedClasses;

  /**
   * The set of function types that checked, both explicity through tests of
   * typedefs and implicitly through type annotations in checked mode.
   */
  Set<FunctionType> checkedFunctionTypes;

  Map<ClassElement, Set<FunctionType>> checkedGenericFunctionTypes =
      new Map<ClassElement, Set<FunctionType>>();

  Set<FunctionType> checkedNonGenericFunctionTypes =
      new Set<FunctionType>();

  /**
   * List of expressions and statements that will be included in the
   * precompiled function.
   *
   * To save space, dart2js normally generates constructors and accessors
   * dynamically. This doesn't work in CSP mode, and may impact startup time
   * negatively. So dart2js will emit these functions to a separate file that
   * can be optionally included to support CSP mode or for faster startup.
   */
  List<jsAst.Node> precompiledFunction = <jsAst.Node>[];

  List<jsAst.Expression> precompiledConstructorNames = <jsAst.Expression>[];

  // True if Isolate.makeConstantList is needed.
  bool hasMakeConstantList = false;

  /**
   * For classes and libraries, record code for static/top-level members.
   * Later, this code is emitted when the class or library is emitted.
   * See [bufferForElement].
   */
  // TODO(ahe): Generate statics with their class, and store only libraries in
  // this map.
  final Map<Element, List<CodeBuffer>> elementBuffers =
      new Map<Element, List<CodeBuffer>>();

  void registerDynamicFunctionTypeCheck(FunctionType functionType) {
    ClassElement classElement = Types.getClassContext(functionType);
    if (classElement != null) {
      checkedGenericFunctionTypes.putIfAbsent(classElement,
          () => new Set<FunctionType>()).add(functionType);
    } else {
      checkedNonGenericFunctionTypes.add(functionType);
    }
  }

  final bool generateSourceMap;

  Iterable<ClassElement> cachedClassesUsingTypeVariableTests;

  Iterable<ClassElement> get classesUsingTypeVariableTests {
    if (cachedClassesUsingTypeVariableTests == null) {
      cachedClassesUsingTypeVariableTests = compiler.codegenWorld.isChecks
          .where((DartType t) => t is TypeVariableType)
          .map((TypeVariableType v) => v.element.getEnclosingClass())
          .toList();
    }
    return cachedClassesUsingTypeVariableTests;
  }

  CodeEmitterTask(Compiler compiler, Namer namer, this.generateSourceMap)
      : mainBuffer = new CodeBuffer(),
        this.namer = namer,
        constantEmitter = new ConstantEmitter(compiler, namer),
        super(compiler) {
    nativeEmitter = new NativeEmitter(this);
    containerBuilder.task = this;
  }

  void addComment(String comment, CodeBuffer buffer) {
    buffer.write(jsAst.prettyPrint(js.comment(comment), compiler));
  }

  void computeRequiredTypeChecks() {
    assert(checkedClasses == null && checkedFunctionTypes == null);

    backend.rti.addImplicitChecks(compiler.codegenWorld,
                                  classesUsingTypeVariableTests);

    checkedClasses = new Set<ClassElement>();
    checkedFunctionTypes = new Set<FunctionType>();
    compiler.codegenWorld.isChecks.forEach((DartType t) {
      if (t is InterfaceType) {
        checkedClasses.add(t.element);
      } else if (t is FunctionType) {
        checkedFunctionTypes.add(t);
      }
    });
  }

  ClassElement computeMixinClass(MixinApplicationElement mixinApplication) {
    ClassElement mixin = mixinApplication.mixin;
    while (mixin.isMixinApplication) {
      mixinApplication = mixin;
      mixin = mixinApplication.mixin;
    }
    return mixin;
  }

  jsAst.Expression constantReference(Constant value) {
    return constantEmitter.reference(value);
  }

  jsAst.Expression constantInitializerExpression(Constant value) {
    return constantEmitter.initializationExpression(value);
  }

  String get name => 'CodeEmitter';

  String get currentGenerateAccessorName
      => '${namer.CURRENT_ISOLATE}.\$generateAccessor';
  String get generateAccessorHolder
      => '$isolatePropertiesName.\$generateAccessor';
  String get finishClassesProperty
      => r'$finishClasses';
  String get finishClassesName
      => '${namer.isolateName}.$finishClassesProperty';
  String get finishIsolateConstructorName
      => '${namer.isolateName}.\$finishIsolateConstructor';
  String get isolatePropertiesName
      => '${namer.isolateName}.${namer.isolatePropertiesName}';
  String get lazyInitializerName
      => '${namer.isolateName}.\$lazy';

  // Compact field specifications.  The format of the field specification is
  // <accessorName>:<fieldName><suffix> where the suffix and accessor name
  // prefix are optional.  The suffix directs the generation of getter and
  // setter methods.  Each of the getter and setter has two bits to determine
  // the calling convention.  Setter listed below, getter is similar.
  //
  //     00: no setter
  //     01: function(value) { this.field = value; }
  //     10: function(receiver, value) { receiver.field = value; }
  //     11: function(receiver, value) { this.field = value; }
  //
  // The suffix encodes 4 bits using three ASCII ranges of non-identifier
  // characters.
  static const FIELD_CODE_CHARACTERS = r"<=>?@{|}~%&'()*";
  static const NO_FIELD_CODE = 0;
  static const FIRST_FIELD_CODE = 1;
  static const RANGE1_FIRST = 0x3c;   //  <=>?@    encodes 1..5
  static const RANGE1_LAST = 0x40;
  static const RANGE2_FIRST = 0x7b;   //  {|}~     encodes 6..9
  static const RANGE2_LAST = 0x7e;
  static const RANGE3_FIRST = 0x25;   //  %&'()*+  encodes 10..16
  static const RANGE3_LAST = 0x2b;
  static const REFLECTION_MARKER = 0x2d;

  jsAst.FunctionDeclaration get generateAccessorFunction {
    const RANGE1_SIZE = RANGE1_LAST - RANGE1_FIRST + 1;
    const RANGE2_SIZE = RANGE2_LAST - RANGE2_FIRST + 1;
    const RANGE1_ADJUST = - (FIRST_FIELD_CODE - RANGE1_FIRST);
    const RANGE2_ADJUST = - (FIRST_FIELD_CODE + RANGE1_SIZE - RANGE2_FIRST);
    const RANGE3_ADJUST =
        - (FIRST_FIELD_CODE + RANGE1_SIZE + RANGE2_SIZE - RANGE3_FIRST);

    String receiverParamName = compiler.enableMinification ? "r" : "receiver";
    String valueParamName = compiler.enableMinification ? "v" : "value";
    String reflectableField = namer.reflectableField;

    // function generateAccessor(field, prototype, cls) {
    jsAst.Fun fun = js.fun(['field', 'accessors', 'cls'], [
      js('var len = field.length'),
      js('var code = field.charCodeAt(len - 1)'),
      js('var reflectable = false'),
      js.if_('code == $REFLECTION_MARKER', [
          js('len--'),
          js('code = field.charCodeAt(len - 1)'),
          js('field = field.substring(0, len)'),
          js('reflectable = true')
      ]),
      js('code = ((code >= $RANGE1_FIRST) && (code <= $RANGE1_LAST))'
          '    ? code - $RANGE1_ADJUST'
          '    : ((code >= $RANGE2_FIRST) && (code <= $RANGE2_LAST))'
          '      ? code - $RANGE2_ADJUST'
          '      : ((code >= $RANGE3_FIRST) && (code <= $RANGE3_LAST))'
          '        ? code - $RANGE3_ADJUST'
          '        : $NO_FIELD_CODE'),

      // if (needsAccessor) {
      js.if_('code', [
        js('var getterCode = code & 3'),
        js('var setterCode = code >> 2'),
        js('var accessorName = field = field.substring(0, len - 1)'),

        js('var divider = field.indexOf(":")'),
        js.if_('divider > 0', [  // Colon never in first position.
          js('accessorName = field.substring(0, divider)'),
          js('field = field.substring(divider + 1)')
        ]),

        // if (needsGetter) {
        js.if_('getterCode', [
          js('var args = (getterCode & 2) ? "$receiverParamName" : ""'),
          js('var receiver = (getterCode & 1) ? "this" : "$receiverParamName"'),
          js('var body = "return " + receiver + "." + field'),
          js('var property ='
             ' cls + ".prototype.${namer.getterPrefix}" + accessorName + "="'),
          js('var fn = "function(" + args + "){" + body + "}"'),
          js.if_(
              'reflectable',
              js('accessors.push(property + "\$reflectable(" + fn + ");\\n")'),
              js('accessors.push(property + fn + ";\\n")')),
        ]),

        // if (needsSetter) {
        js.if_('setterCode', [
          js('var args = (setterCode & 2)'
              '  ? "$receiverParamName,${_}$valueParamName"'
              '  : "$valueParamName"'),
          js('var receiver = (setterCode & 1) ? "this" : "$receiverParamName"'),
          js('var body = receiver + "." + field + "$_=$_$valueParamName"'),
          js('var property ='
             ' cls + ".prototype.${namer.setterPrefix}" + accessorName + "="'),
          js('var fn = "function(" + args + "){" + body + "}"'),
          js.if_(
              'reflectable',
              js('accessors.push(property + "\$reflectable(" + fn + ");\\n")'),
              js('accessors.push(property + fn + ";\\n")')),
        ]),

      ]),

      // return field;
      js.return_('field')
    ]);

    return new jsAst.FunctionDeclaration(
        new jsAst.VariableDeclaration('generateAccessor'),
        fun);
  }

  List get defineClassFunction {
    // First the class name, then the field names in an array and the members
    // (inside an Object literal).
    // The caller can also pass in the constructor as a function if needed.
    //
    // Example:
    // defineClass("A", ["x", "y"], {
    //  foo$1: function(y) {
    //   print(this.x + y);
    //  },
    //  bar$2: function(t, v) {
    //   this.x = t - v;
    //  },
    // });

    var defineClass = js.fun(['name', 'cls', 'fields'], [
      js('var accessors = []'),

      js('var str = "function " + cls + "("'),
      js('var body = ""'),

      js.for_('var i = 0', 'i < fields.length', 'i++', [
        js.if_('i != 0', js('str += ", "')),

        js('var field = generateAccessor(fields[i], accessors, cls)'),
        js('var parameter = "parameter_" + field'),
        js('str += parameter'),
        js('body += ("this." + field + " = " + parameter + ";\\n")')
      ]),
      js('str += ") {\\n" + body + "}\\n"'),
      js('str += cls + ".builtin\$cls=\\"" + name + "\\";\\n"'),
      js('str += "\$desc=\$collectedClasses." + cls + ";\\n"'),
      js('str += "if(\$desc instanceof Array) \$desc = \$desc[1];\\n"'),
      js('str += cls + ".prototype = \$desc;\\n"'),
      js.if_(
          'typeof defineClass.name != "string"',
          [js('str += cls + ".name=\\"" + cls + "\\";\\n"')]),
      js('str += accessors.join("")'),

      js.return_('str')
    ]);
    // Declare a function called "generateAccessor".  This is used in
    // defineClassFunction (it's a local declaration in init()).
    return [
        generateAccessorFunction,
        js('$generateAccessorHolder = generateAccessor'),
        new jsAst.FunctionDeclaration(
            new jsAst.VariableDeclaration('defineClass'), defineClass) ];
  }

  /** Needs defineClass to be defined. */
  List buildInheritFrom() {
    return [
      js('var inheritFrom = #',
          js.fun([], [
              new jsAst.FunctionDeclaration(
                  new jsAst.VariableDeclaration('tmp'), js.fun([], [])),
              js('var hasOwnProperty = Object.prototype.hasOwnProperty'),
              js.return_(js.fun(['constructor', 'superConstructor'], [
                  js('tmp.prototype = superConstructor.prototype'),
                  js('var object = new tmp()'),
                  js('var properties = constructor.prototype'),
                  js.forIn('member', 'properties',
                    js.if_('hasOwnProperty.call(properties, member)',
                           js('object[member] = properties[member]'))),
                  js('object.constructor = constructor'),
                  js('constructor.prototype = object'),
                  js.return_('object')
              ]))])())];
  }

  static const MAX_MINIFIED_LENGTH_FOR_DIFF_ENCODING = 4;

  // If we need fewer than this many noSuchMethod handlers we can save space by
  // just emitting them in JS, rather than emitting the JS needed to generate
  // them at run time.
  static const VERY_FEW_NO_SUCH_METHOD_HANDLERS = 10;

  /**
   * Adds (at runtime) the handlers to the Object class which catch calls to
   * methods that the object does not have.  The handlers create an invocation
   * mirror object.
   *
   * The current version only gives you the minified name when minifying (when
   * not minifying this method is not called).
   *
   * In order to generate the noSuchMethod handlers we only need the minified
   * name of the method.  We test the first character of the minified name to
   * determine if it is a getter or a setter, and we use the arguments array at
   * runtime to get the number of arguments and their values.  If the method
   * involves named arguments etc. then we don't handle it here, but emit the
   * handler method directly on the Object class.
   *
   * The minified names are mostly 1-4 character names, which we emit in sorted
   * order (primary key is length, secondary ordering is lexicographic).  This
   * gives an order like ... dD dI dX da ...
   *
   * Gzip is good with repeated text, but it can't diff-encode, so we do that
   * for it.  We encode the minified names in a comma-separated string, but all
   * the 1-4 character names are encoded before the first comma as a series of
   * base 26 numbers.  The last digit of each number is lower case, the others
   * are upper case, so 1 is "b" and 26 is "Ba".
   *
   * We think of the minified names as base 88 numbers using the ASCII
   * characters from # to z.  The base 26 numbers each encode the delta from
   * the previous minified name to the next.  So if there is a minified name
   * called Df and the next is Dh, then they are 2971 and 2973 when thought of
   * as base 88 numbers.  The difference is 2, which is "c" in lower-case-
   * terminated base 26.
   *
   * The reason we don't encode long minified names with this method is that
   * decoding the base 88 numbers would overflow JavaScript's puny integers.
   *
   * There are some selectors that have a special calling convention (because
   * they are called with the receiver as the first argument).  They need a
   * slightly different noSuchMethod handler, so we handle these first.
   */
  void addTrivialNsmHandlers(List<jsAst.Node> statements) {
    if (trivialNsmHandlers.length == 0) return;
    // Sort by calling convention, JS name length and by JS name.
    trivialNsmHandlers.sort((a, b) {
      bool aIsIntercepted = backend.isInterceptedName(a.name);
      bool bIsIntercepted = backend.isInterceptedName(b.name);
      if (aIsIntercepted != bIsIntercepted) return aIsIntercepted ? -1 : 1;
      String aName = namer.invocationMirrorInternalName(a);
      String bName = namer.invocationMirrorInternalName(b);
      if (aName.length != bName.length) return aName.length - bName.length;
      return aName.compareTo(bName);
    });

    // Find out how many selectors there are with the special calling
    // convention.
    int firstNormalSelector = trivialNsmHandlers.length;
    for (int i = 0; i < trivialNsmHandlers.length; i++) {
      if (!backend.isInterceptedName(trivialNsmHandlers[i].name)) {
        firstNormalSelector = i;
        break;
      }
    }

    // Get the short names (JS names, perhaps minified).
    Iterable<String> shorts = trivialNsmHandlers.map((selector) =>
         namer.invocationMirrorInternalName(selector));
    final diffShorts = <String>[];
    var diffEncoding = new StringBuffer();

    // Treat string as a number in base 88 with digits in ASCII order from # to
    // z.  The short name sorting is based on length, and uses ASCII order for
    // equal length strings so this means that names are ascending.  The hash
    // character, #, is never given as input, but we need it because it's the
    // implicit leading zero (otherwise we could not code names with leading
    // dollar signs).
    int fromBase88(String x) {
      int answer = 0;
      for (int i = 0; i < x.length; i++) {
        int c = x.codeUnitAt(i);
        // No support for Unicode minified identifiers in JS.
        assert(c >= $$ && c <= $z);
        answer *= 88;
        answer += c - $HASH;
      }
      return answer;
    }

    // Big endian encoding, A = 0, B = 1...
    // A lower case letter terminates the number.
    String toBase26(int x) {
      int c = x;
      var encodingChars = <int>[];
      encodingChars.add($a + (c % 26));
      while (true) {
        c ~/= 26;
        if (c == 0) break;
        encodingChars.add($A + (c % 26));
      }
      return new String.fromCharCodes(encodingChars.reversed.toList());
    }

    bool minify = compiler.enableMinification;
    bool useDiffEncoding = minify && shorts.length > 30;

    int previous = 0;
    int nameCounter = 0;
    for (String short in shorts) {
      // Emit period that resets the diff base to zero when we switch to normal
      // calling convention (this avoids the need to code negative diffs).
      if (useDiffEncoding && nameCounter == firstNormalSelector) {
        diffEncoding.write(".");
        previous = 0;
      }
      if (short.length <= MAX_MINIFIED_LENGTH_FOR_DIFF_ENCODING &&
          useDiffEncoding) {
        int base63 = fromBase88(short);
        int diff = base63 - previous;
        previous = base63;
        String base26Diff = toBase26(diff);
        diffEncoding.write(base26Diff);
      } else {
        if (useDiffEncoding || diffEncoding.length != 0) {
          diffEncoding.write(",");
        }
        diffEncoding.write(short);
      }
      nameCounter++;
    }

    // Startup code that loops over the method names and puts handlers on the
    // Object class to catch noSuchMethod invocations.
    ClassElement objectClass = compiler.objectClass;
    String createInvocationMirror = namer.isolateAccess(
        backend.getCreateInvocationMirror());
    String noSuchMethodName = namer.publicInstanceMethodNameByArity(
        Compiler.NO_SUCH_METHOD, Compiler.NO_SUCH_METHOD_ARG_COUNT);
    var type = 0;
    if (useDiffEncoding) {
      statements.addAll([
        js('var objectClassObject = '
           '        collectedClasses["${namer.getNameOfClass(objectClass)}"],'
           '    shortNames = "$diffEncoding".split(","),'
           '    nameNumber = 0,'
           '    diffEncodedString = shortNames[0],'
           '    calculatedShortNames = [0, 1]'),  // 0, 1 are args for splice.
        js.if_('objectClassObject instanceof Array',
               js('objectClassObject = objectClassObject[1]')),
        js.for_('var i = 0', 'i < diffEncodedString.length', 'i++', [
          js('var codes = [],'
             '    diff = 0,'
             '    digit = diffEncodedString.charCodeAt(i)'),
          js.if_('digit == ${$PERIOD}', [
            js('nameNumber = 0'),
            js('digit = diffEncodedString.charCodeAt(++i)')
          ]),
          js.while_('digit <= ${$Z}', [
            js('diff *= 26'),
            js('diff += (digit - ${$A})'),
            js('digit = diffEncodedString.charCodeAt(++i)')
          ]),
          js('diff *= 26'),
          js('diff += (digit - ${$a})'),
          js('nameNumber += diff'),
          js.for_('var remaining = nameNumber',
                  'remaining > 0',
                  'remaining = (remaining / 88) | 0', [
            js('codes.unshift(${$HASH} + remaining % 88)')
          ]),
          js('calculatedShortNames.push('
             '    String.fromCharCode.apply(String, codes))')
        ]),
        js('shortNames.splice.apply(shortNames, calculatedShortNames)')
      ]);
    } else {
      // No useDiffEncoding version.
      Iterable<String> longs = trivialNsmHandlers.map((selector) =>
             selector.invocationMirrorMemberName);
      String longNamesConstant = minify ? "" :
          ',longNames = "${longs.join(",")}".split(",")';
      statements.add(
        js('var objectClassObject = '
           '        collectedClasses["${namer.getNameOfClass(objectClass)}"],'
           '    shortNames = "$diffEncoding".split(",")'
           '    $longNamesConstant'));
      statements.add(
          js.if_('objectClassObject instanceof Array',
                 js('objectClassObject = objectClassObject[1]')));
    }

    String sliceOffset = ', (j < $firstNormalSelector) ? 1 : 0';
    if (firstNormalSelector == 0) sliceOffset = '';
    if (firstNormalSelector == shorts.length) sliceOffset = ', 1';

    String whatToPatch = nativeEmitter.handleNoSuchMethod ?
                         "Object.prototype" :
                         "objectClassObject";

    var params = ['name', 'short', 'type'];
    var sliceOffsetParam = '';
    var slice = 'Array.prototype.slice.call';
    if (!sliceOffset.isEmpty) {
      sliceOffsetParam = ', sliceOffset';
      params.add('sliceOffset');
    }
    statements.addAll([
      js.for_('var j = 0', 'j < shortNames.length', 'j++', [
        js('var type = 0'),
        js('var short = shortNames[j]'),
        js.if_('short[0] == "${namer.getterPrefix[0]}"', js('type = 1')),
        js.if_('short[0] == "${namer.setterPrefix[0]}"', js('type = 2')),
        // Generate call to:
        // createInvocationMirror(String name, internalName, type, arguments,
        //                        argumentNames)
        js('$whatToPatch[short] = #(${minify ? "shortNames" : "longNames"}[j], '
                                    'short, type$sliceOffset)',
           js.fun(params, [js.return_(js.fun([],
               [js.return_(js(
                   'this.$noSuchMethodName('
                       'this, '
                       '$createInvocationMirror('
                           'name, short, type, '
                           '$slice(arguments$sliceOffsetParam), []))'))]))]))
      ])
    ]);
  }

  jsAst.Fun get finishClassesFunction {
    // Class descriptions are collected in a JS object.
    // 'finishClasses' takes all collected descriptions and sets up
    // the prototype.
    // Once set up, the constructors prototype field satisfy:
    //  - it contains all (local) members.
    //  - its internal prototype (__proto__) points to the superclass'
    //    prototype field.
    //  - the prototype's constructor field points to the JavaScript
    //    constructor.
    // For engines where we have access to the '__proto__' we can manipulate
    // the object literal directly. For other engines we have to create a new
    // object and copy over the members.

    String reflectableField = namer.reflectableField;
    List<jsAst.Node> statements = [
      js('var pendingClasses = {}'),
      js.if_('!init.allClasses', js('init.allClasses = {}')),
      js('var allClasses = init.allClasses'),

      optional(
          DEBUG_FAST_OBJECTS,
          js('print("Number of classes: "'
             r' + Object.getOwnPropertyNames($$).length)')),

      js('var hasOwnProperty = Object.prototype.hasOwnProperty'),

      js.if_('typeof dart_precompiled == "function"',
          [js('var constructors = dart_precompiled(collectedClasses)')],

          [js('var combinedConstructorFunction = "function \$reflectable(fn){'
              'fn.$reflectableField=1;return fn};\\n"+ "var \$desc;\\n"'),
           js('var constructorsList = []')]),
      js.forIn('cls', 'collectedClasses', [
        js.if_('hasOwnProperty.call(collectedClasses, cls)', [
          js('var desc = collectedClasses[cls]'),
          js.if_('desc instanceof Array', js('desc = desc[1]')),

          /* The 'fields' are either a constructor function or a
           * string encoding fields, constructor and superclass.  Get
           * the superclass and the fields in the format
           *   '[name/]Super;field1,field2'
           * from the null-string property on the descriptor.
           * The 'name/' is optional and contains the name that should be used
           * when printing the runtime type string.  It is used, for example, to
           * print the runtime type JSInt as 'int'.
           */
          js('var classData = desc[""], supr, name = cls, fields = classData'),
          optional(
              backend.hasRetainedMetadata,
              js.if_('typeof classData == "object" && '
                     'classData instanceof Array',
                     [js('classData = fields = classData[0]')])),

          js.if_('typeof classData == "string"', [
            js('var split = classData.split("/")'),
            js.if_('split.length == 2', [
              js('name = split[0]'),
              js('fields = split[1]')
            ])
          ]),

          js('var s = fields.split(";")'),
          js('fields = s[1] == "" ? [] : s[1].split(",")'),
          js('supr = s[0]'),

          optional(needsMixinSupport, js.if_('supr && supr.indexOf("+") > 0', [
            js('s = supr.split("+")'),
            js('supr = s[0]'),
            js('var mixin = collectedClasses[s[1]]'),
            js.if_('mixin instanceof Array', js('mixin = mixin[1]')),
            js.forIn('d', 'mixin', [
              js.if_('hasOwnProperty.call(mixin, d)'
                     '&& !hasOwnProperty.call(desc, d)',
                js('desc[d] = mixin[d]'))
            ]),
          ])),

          js.if_('typeof dart_precompiled != "function"',
              [js('combinedConstructorFunction +='
                  ' defineClass(name, cls, fields)'),
                 js('constructorsList.push(cls)')]),
          js.if_('supr', js('pendingClasses[cls] = supr'))
        ])
      ]),
      js.if_('typeof dart_precompiled != "function"',
          [js('combinedConstructorFunction +='
              ' "return [\\n  " + constructorsList.join(",\\n  ") + "\\n]"'),
           js('var constructors ='
              ' new Function("\$collectedClasses", combinedConstructorFunction)'
              '(collectedClasses)'),
           js('combinedConstructorFunction = null')]),
      js.for_('var i = 0', 'i < constructors.length', 'i++', [
        js('var constructor = constructors[i]'),
        js('var cls = constructor.name'),
        js('var desc = collectedClasses[cls]'),
        js('var globalObject = isolateProperties'),
        js.if_('desc instanceof Array', [
            js('globalObject = desc[0] || isolateProperties'),
            js('desc = desc[1]')
        ]),
        optional(backend.isTreeShakingDisabled,
                 js('constructor["${namer.metadataField}"] = desc')),
        js('allClasses[cls] = constructor'),
        js('globalObject[cls] = constructor'),
      ]),
      js('constructors = null'),

      js('var finishedClasses = {}'),

      buildFinishClass(),
    ];

    addTrivialNsmHandlers(statements);

    statements.add(
      js.forIn('cls', 'pendingClasses', js('finishClass(cls)'))
    );
    // function(collectedClasses,
    //          isolateProperties,
    //          existingIsolateProperties)
    return js.fun(['collectedClasses', 'isolateProperties',
                   'existingIsolateProperties'], statements);
  }

  jsAst.Node optional(bool condition, jsAst.Node node) {
    return condition ? node : new jsAst.EmptyStatement();
  }

  jsAst.FunctionDeclaration buildFinishClass() {
    // function finishClass(cls) {
    jsAst.Fun fun = js.fun(['cls'], [

      // TODO(8540): Remove this work around.
      /* Opera does not support 'getOwnPropertyNames'. Therefore we use
         hasOwnProperty instead. */
      js('var hasOwnProperty = Object.prototype.hasOwnProperty'),

      // if (hasOwnProperty.call(finishedClasses, cls)) return;
      js.if_('hasOwnProperty.call(finishedClasses, cls)',
             js.return_()),

      js('finishedClasses[cls] = true'),

      js('var superclass = pendingClasses[cls]'),

      // The superclass is only false (empty string) for Dart's Object class.
      // The minifier together with noSuchMethod can put methods on the
      // Object.prototype object, and they show through here, so we check that
      // we have a string.
      js.if_('!superclass || typeof superclass != "string"', js.return_()),
      js('finishClass(superclass)'),
      js('var constructor = allClasses[cls]'),
      js('var superConstructor = allClasses[superclass]'),

      js.if_(js('!superConstructor'),
             js('superConstructor ='
                    'existingIsolateProperties[superclass]')),

      js('prototype = inheritFrom(constructor, superConstructor)'),
    ]);

    return new jsAst.FunctionDeclaration(
        new jsAst.VariableDeclaration('finishClass'),
        fun);
  }

  jsAst.Fun get finishIsolateConstructorFunction {
    // We replace the old Isolate function with a new one that initializes
    // all its fields with the initial (and often final) value of all globals.
    //
    // We also copy over old values like the prototype, and the
    // isolateProperties themselves.
    return js.fun('oldIsolate', [
      js('var isolateProperties = oldIsolate.${namer.isolatePropertiesName}'),
      new jsAst.FunctionDeclaration(
        new jsAst.VariableDeclaration('Isolate'),
          js.fun([], [
            js('var hasOwnProperty = Object.prototype.hasOwnProperty'),
            js.forIn('staticName', 'isolateProperties',
              js.if_('hasOwnProperty.call(isolateProperties, staticName)',
                js('this[staticName] = isolateProperties[staticName]'))),
            // Use the newly created object as prototype. In Chrome,
            // this creates a hidden class for the object and makes
            // sure it is fast to access.
            new jsAst.FunctionDeclaration(
              new jsAst.VariableDeclaration('ForceEfficientMap'),
              js.fun([], [])),
            js('ForceEfficientMap.prototype = this'),
            js('new ForceEfficientMap()')])),
      js('Isolate.prototype = oldIsolate.prototype'),
      js('Isolate.prototype.constructor = Isolate'),
      js('Isolate.${namer.isolatePropertiesName} = isolateProperties'),
      optional(needsDefineClass,
               js('Isolate.$finishClassesProperty ='
                  ' oldIsolate.$finishClassesProperty')),
      optional(hasMakeConstantList,
               js('Isolate.makeConstantList = oldIsolate.makeConstantList')),
      js.return_('Isolate')]);
  }

  jsAst.Fun get lazyInitializerFunction {
    // function(prototype, staticName, fieldName, getterName, lazyValue) {
    var parameters = <String>['prototype', 'staticName', 'fieldName',
                              'getterName', 'lazyValue'];
    return js.fun(parameters, addLazyInitializerLogic());
  }

  List addLazyInitializerLogic() {
    String isolate = namer.CURRENT_ISOLATE;
    String cyclicThrow = namer.isolateAccess(backend.getCyclicThrowHelper());
    var lazies = [];
    if (backend.rememberLazies) {
      lazies = [
          js.if_('!init.lazies', js('init.lazies = {}')),
          js('init.lazies[fieldName] = getterName')];
    }

    return lazies..addAll([
      js('var sentinelUndefined = {}'),
      js('var sentinelInProgress = {}'),
      js('prototype[fieldName] = sentinelUndefined'),

      // prototype[getterName] = function()
      js('prototype[getterName] = #', js.fun([], [
        js('var result = $isolate[fieldName]'),

        // try
        js.try_([
          js.if_('result === sentinelUndefined', [
            js('$isolate[fieldName] = sentinelInProgress'),

            // try
            js.try_([
              js('result = $isolate[fieldName] = lazyValue()'),

            ], finallyPart: [
              // Use try-finally, not try-catch/throw as it destroys the
              // stack trace.

              // if (result === sentinelUndefined)
              js.if_('result === sentinelUndefined', [
                // if ($isolate[fieldName] === sentinelInProgress)
                js.if_('$isolate[fieldName] === sentinelInProgress', [
                  js('$isolate[fieldName] = null'),
                ])
              ])
            ])
          ], /* else */ [
            js.if_('result === sentinelInProgress',
              js('$cyclicThrow(staticName)')
            )
          ]),

          // return result;
          js.return_('result')

        ], finallyPart: [
          js('$isolate[getterName] = #',
             js.fun([], [js.return_('this[fieldName]')]))
        ])
      ]))
    ]);
  }

  List buildDefineClassAndFinishClassFunctionsIfNecessary() {
    if (!needsDefineClass) return [];
    return defineClassFunction
    ..addAll(buildInheritFrom())
    ..addAll([
      js('$finishClassesName = #', finishClassesFunction)
    ]);
  }

  List buildLazyInitializerFunctionIfNecessary() {
    if (!needsLazyInitializer) return [];

    return [js('$lazyInitializerName = #', lazyInitializerFunction)];
  }

  List buildFinishIsolateConstructor() {
    return [
      js('$finishIsolateConstructorName = #', finishIsolateConstructorFunction)
    ];
  }

  void emitFinishIsolateConstructorInvocation(CodeBuffer buffer) {
    String isolate = namer.isolateName;
    buffer.write("$isolate = $finishIsolateConstructorName($isolate)$N");
  }

  bool fieldNeedsGetter(VariableElement field) {
    assert(field.isField());
    if (fieldAccessNeverThrows(field)) return false;
    return backend.shouldRetainGetter(field)
        || compiler.codegenWorld.hasInvokedGetter(field, compiler);
  }

  bool fieldNeedsSetter(VariableElement field) {
    assert(field.isField());
    if (fieldAccessNeverThrows(field)) return false;
    return (!field.modifiers.isFinalOrConst())
        && (backend.shouldRetainSetter(field)
            || compiler.codegenWorld.hasInvokedSetter(field, compiler));
  }

  // We never access a field in a closure (a captured variable) without knowing
  // that it is there.  Therefore we don't need to use a getter (that will throw
  // if the getter method is missing), but can always access the field directly.
  static bool fieldAccessNeverThrows(VariableElement field) {
    return field is ClosureFieldElement;
  }

  /// Returns the "reflection name" of an [Element] or [Selector].
  /// The reflection name of a getter 'foo' is 'foo'.
  /// The reflection name of a setter 'foo' is 'foo='.
  /// The reflection name of a method 'foo' is 'foo:N:M:O', where N is the
  /// number of required arguments, M is the number of optional arguments, and
  /// O is the named arguments.
  /// The reflection name of a constructor is similar to a regular method but
  /// starts with 'new '.
  /// The reflection name of class 'C' is 'C'.
  /// An anonymous mixin application has no reflection name.
  /// This is used by js_mirrors.dart.
  String getReflectionName(elementOrSelector, String mangledName) {
    SourceString name = elementOrSelector.name;
    if (!backend.shouldRetainName(name)) {
      if (name == const SourceString('') && elementOrSelector is Element) {
        // Make sure to retain names of unnamed constructors.
        if (!backend.isNeededForReflection(elementOrSelector)) return null;
      } else {
        return null;
      }
    }
    // TODO(ahe): Enable the next line when I can tell the difference between
    // an instance method and a global.  They may have the same mangled name.
    // if (recordedMangledNames.contains(mangledName)) return null;
    recordedMangledNames.add(mangledName);
    return getReflectionNameInternal(elementOrSelector, mangledName);
  }

  String getReflectionNameInternal(elementOrSelector, String mangledName) {
    String name = elementOrSelector.name.slowToString();
    if (elementOrSelector.isGetter()) return name;
    if (elementOrSelector.isSetter()) {
      if (!mangledName.startsWith(namer.setterPrefix)) return '$name=';
      String base = mangledName.substring(namer.setterPrefix.length);
      String getter = '${namer.getterPrefix}$base';
      mangledFieldNames[getter] = name;
      recordedMangledNames.add(getter);
      // TODO(karlklose,ahe): we do not actually need to store information
      // about the name of this setter in the output, but it is needed for
      // marking the function as invokable by reflection.
      return '$name=';
    }
    if (elementOrSelector is Selector
        || elementOrSelector.isFunction()
        || elementOrSelector.isConstructor()) {
      int requiredParameterCount;
      int optionalParameterCount;
      String namedArguments = '';
      bool isConstructor = false;
      if (elementOrSelector is Selector) {
        Selector selector = elementOrSelector;
        requiredParameterCount = selector.argumentCount;
        optionalParameterCount = 0;
        namedArguments = namedParametersAsReflectionNames(selector);
      } else {
        FunctionElement function = elementOrSelector;
        if (function.isConstructor()) {
          isConstructor = true;
          name = Elements.reconstructConstructorName(function);
        }
        requiredParameterCount = function.requiredParameterCount(compiler);
        optionalParameterCount = function.optionalParameterCount(compiler);
        FunctionSignature signature = function.computeSignature(compiler);
        if (signature.optionalParametersAreNamed) {
          var names = [];
          for (Element e in signature.optionalParameters) {
            names.add(e.name);
          }
          Selector selector = new Selector.call(
              function.name,
              function.getLibrary(),
              requiredParameterCount,
              names);
          namedArguments = namedParametersAsReflectionNames(selector);
        } else {
          // Named parameters are handled differently by mirrors.  For unnamed
          // parameters, they are actually required if invoked
          // reflectively. Also, if you have a method c(x) and c([x]) they both
          // get the same mangled name, so they must have the same reflection
          // name.
          requiredParameterCount += optionalParameterCount;
          optionalParameterCount = 0;
        }
      }
      String suffix =
          // TODO(ahe): We probably don't need optionalParameterCount in the
          // reflection name.
          '$name:$requiredParameterCount:$optionalParameterCount'
          '$namedArguments';
      return (isConstructor) ? 'new $suffix' : suffix;
    }
    Element element = elementOrSelector;
    if (element.isGenerativeConstructorBody()) {
      return null;
    } else if (element.isClass()) {
      ClassElement cls = element;
      if (cls.isUnnamedMixinApplication) return null;
      return cls.name.slowToString();
    }
    throw compiler.internalErrorOnElement(
        element, 'Do not know how to reflect on this $element');
  }

  String namedParametersAsReflectionNames(Selector selector) {
    if (selector.getOrderedNamedArguments().isEmpty) return '';
    String names = selector.getOrderedNamedArguments().map(
        (x) => x.slowToString()).join(':');
    return ':$names';
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [classElement] must be a declaration element.
   */
  void emitInstanceMembers(ClassElement classElement,
                           ClassBuilder builder) {
    assert(invariant(classElement, classElement.isDeclaration));

    void visitMember(ClassElement enclosing, Element member) {
      assert(invariant(classElement, member.isDeclaration));
      if (member.isInstanceMember()) {
        containerBuilder.addMember(member, builder);
      }
    }

    classElement.implementation.forEachMember(
        visitMember,
        includeBackendMembers: true);

    if (identical(classElement, compiler.objectClass)
        && compiler.enabledNoSuchMethod) {
      // Emit the noSuchMethod handlers on the Object prototype now,
      // so that the code in the dynamicFunction helper can find
      // them. Note that this helper is invoked before analyzing the
      // full JS script.
      if (!nativeEmitter.handleNoSuchMethod) {
        emitNoSuchMethodHandlers(builder.addProperty);
      }
    }
  }

  void emitIsTests(ClassElement classElement, ClassBuilder builder) {
    assert(invariant(classElement, classElement.isDeclaration));

    void generateIsTest(Element other) {
      if (other == compiler.objectClass && other != classElement) {
        // Avoid emitting [:$isObject:] on all classes but [Object].
        return;
      }
      other = backend.getImplementationClass(other);
      builder.addProperty(namer.operatorIs(other), js('true'));
    }

    void generateIsFunctionTypeTest(FunctionType type) {
      String operator = namer.operatorIsType(type);
      builder.addProperty(operator, new jsAst.LiteralBool(true));
    }

    void generateFunctionTypeSignature(Element method, FunctionType type) {
      assert(method.isImplementation);
      jsAst.Expression thisAccess = new jsAst.This();
      Node node = method.parseNode(compiler);
      ClosureClassMap closureData =
          compiler.closureToClassMapper.closureMappingCache[node];
      if (closureData != null) {
        Element thisElement =
            closureData.freeVariableMapping[closureData.thisElement];
        if (thisElement != null) {
          assert(thisElement.hasFixedBackendName());
          String thisName = thisElement.fixedBackendName();
          thisAccess = js('this')[js.string(thisName)];
        }
      }
      RuntimeTypes rti = backend.rti;
      jsAst.Expression encoding = rti.getSignatureEncoding(type, thisAccess);
      String operatorSignature = namer.operatorSignature();
      builder.addProperty(operatorSignature, encoding);
    }

    void generateSubstitution(ClassElement cls, {bool emitNull: false}) {
      if (cls.typeVariables.isEmpty) return;
      RuntimeTypes rti = backend.rti;
      jsAst.Expression expression;
      bool needsNativeCheck = nativeEmitter.requiresNativeIsCheck(cls);
      expression = rti.getSupertypeSubstitution(
          classElement, cls, alwaysGenerateFunction: true);
      if (expression == null && (emitNull || needsNativeCheck)) {
        expression = new jsAst.LiteralNull();
      }
      if (expression != null) {
        builder.addProperty(namer.substitutionName(cls), expression);
      }
    }

    generateIsTestsOn(classElement, generateIsTest,
        generateIsFunctionTypeTest, generateFunctionTypeSignature,
        generateSubstitution);
  }

  void emitRuntimeTypeSupport(CodeBuffer buffer) {
    addComment('Runtime type support', buffer);
    RuntimeTypes rti = backend.rti;
    TypeChecks typeChecks = rti.requiredChecks;

    // Add checks to the constructors of instantiated classes.
    for (ClassElement cls in typeChecks) {
      // TODO(9556).  The properties added to 'holder' should be generated
      // directly as properties of the class object, not added later.
      String holder = namer.isolateAccess(backend.getImplementationClass(cls));
      for (TypeCheck check in typeChecks[cls]) {
        ClassElement cls = check.cls;
        buffer.write('$holder.${namer.operatorIs(cls)}$_=${_}true$N');
        Substitution substitution = check.substitution;
        if (substitution != null) {
          CodeBuffer body =
             jsAst.prettyPrint(substitution.getCode(rti, false), compiler);
          buffer.write('$holder.${namer.substitutionName(cls)}$_=${_}');
          buffer.write(body);
          buffer.write('$N');
        }
      };
    }

    void addSignature(FunctionType type) {
      jsAst.Expression encoding = rti.getTypeEncoding(type);
      buffer.add('${namer.signatureName(type)}$_=${_}');
      buffer.write(jsAst.prettyPrint(encoding, compiler));
      buffer.add('$N');
    }

    checkedNonGenericFunctionTypes.forEach(addSignature);

    checkedGenericFunctionTypes.forEach((_, Set<FunctionType> functionTypes) {
      functionTypes.forEach(addSignature);
    });
  }

  /**
   * Returns the classes with constructors used as a 'holder' in
   * [emitRuntimeTypeSupport].
   * TODO(9556): Some cases will go away when the class objects are created as
   * complete.  Not all classes will go away while constructors are referenced
   * from type substitutions.
   */
  Set<ClassElement> classesModifiedByEmitRuntimeTypeSupport() {
    TypeChecks typeChecks = backend.rti.requiredChecks;
    Set<ClassElement> result = new Set<ClassElement>();
    for (ClassElement cls in typeChecks) {
      for (TypeCheck check in typeChecks[cls]) {
        result.add(backend.getImplementationClass(cls));
        break;
      }
    }
    return result;
  }

  /**
   * Calls [addField] for each of the fields of [element].
   *
   * [element] must be a [ClassElement] or a [LibraryElement].
   *
   * If [element] is a [ClassElement], the static fields of the class are
   * visited if [visitStatics] is true and the instance fields are visited if
   * [visitStatics] is false.
   *
   * If [element] is a [LibraryElement], [visitStatics] must be true.
   *
   * When visiting the instance fields of a class, the fields of its superclass
   * are also visited if the class is instantiated.
   *
   * Invariant: [element] must be a declaration element.
   */
  void visitFields(Element element, bool visitStatics, AcceptField f) {
    assert(invariant(element, element.isDeclaration));

    bool isClass = false;
    bool isLibrary = false;
    if (element.isClass()) {
      isClass = true;
    } else if (element.isLibrary()) {
      isLibrary = true;
      assert(invariant(element, visitStatics));
    } else {
      throw new SpannableAssertionFailure(
          element, 'Expected a ClassElement or a LibraryElement.');
    }

    // If the class is never instantiated we still need to set it up for
    // inheritance purposes, but we can simplify its JavaScript constructor.
    bool isInstantiated =
        compiler.codegenWorld.instantiatedClasses.contains(element);

    void visitField(Element holder, VariableElement field) {
      assert(invariant(element, field.isDeclaration));
      SourceString name = field.name;

      // Keep track of whether or not we're dealing with a field mixin
      // into a native class.
      bool isMixinNativeField =
          isClass && element.isNative() && holder.isMixinApplication;

      // See if we can dynamically create getters and setters.
      // We can only generate getters and setters for [element] since
      // the fields of super classes could be overwritten with getters or
      // setters.
      bool needsGetter = false;
      bool needsSetter = false;
      // We need to name shadowed fields differently, so they don't clash with
      // the non-shadowed field.
      bool isShadowed = false;
      if (isLibrary || isMixinNativeField || holder == element) {
        needsGetter = fieldNeedsGetter(field);
        needsSetter = fieldNeedsSetter(field);
      } else {
        ClassElement cls = element;
        isShadowed = cls.isShadowedByField(field);
      }

      if ((isInstantiated && !holder.isNative())
          || needsGetter
          || needsSetter) {
        String accessorName = isShadowed
            ? namer.shadowedFieldName(field)
            : namer.getNameOfField(field);
        String fieldName = field.hasFixedBackendName()
            ? field.fixedBackendName()
            : (isMixinNativeField ? name.slowToString() : accessorName);
        bool needsCheckedSetter = false;
        if (compiler.enableTypeAssertions
            && needsSetter
            && canGenerateCheckedSetter(field)) {
          needsCheckedSetter = true;
          needsSetter = false;
        }
        // Getters and setters with suffixes will be generated dynamically.
        f(field, fieldName, accessorName, needsGetter, needsSetter,
          needsCheckedSetter);
      }
    }

    if (isLibrary) {
      LibraryElement library = element;
      library.implementation.forEachLocalMember((Element member) {
        if (member.isField()) visitField(library, member);
      });
    } else if (visitStatics) {
      ClassElement cls = element;
      cls.implementation.forEachStaticField(visitField);
    } else {
      ClassElement cls = element;
      // TODO(kasperl): We should make sure to only emit one version of
      // overridden fields. Right now, we rely on the ordering so the
      // fields pulled in from mixins are replaced with the fields from
      // the class definition.

      // If a class is not instantiated then we add the field just so we can
      // generate the field getter/setter dynamically. Since this is only
      // allowed on fields that are in [element] we don't need to visit
      // superclasses for non-instantiated classes.
      cls.implementation.forEachInstanceField(
          visitField, includeSuperAndInjectedMembers: isInstantiated);
    }
  }

  void generateReflectionDataForFieldGetterOrSetter(Element member,
                                                    String name,
                                                    ClassBuilder builder,
                                                    {bool isGetter}) {
    Selector selector = isGetter
        ? new Selector.getter(member.name, member.getLibrary())
        : new Selector.setter(member.name, member.getLibrary());
    String reflectionName = getReflectionName(selector, name);
    if (reflectionName != null) {
      var reflectable =
          js(backend.isAccessibleByReflection(member) ? '1' : '0');
      builder.addProperty('+$reflectionName', reflectable);
    }
  }

  void generateGetter(Element member, String fieldName, String accessorName,
                      ClassBuilder builder) {
    String getterName = namer.getterNameFromAccessorName(accessorName);
    ClassElement cls = member.getEnclosingClass();
    String className = namer.getNameOfClass(cls);
    String receiver = backend.isInterceptorClass(cls) ? 'receiver' : 'this';
    List<String> args = backend.isInterceptedMethod(member) ? ['receiver'] : [];
    precompiledFunction.add(
        js('$className.prototype.$getterName = #',
           js.fun(args, js.return_(js('$receiver.$fieldName')))));
    if (backend.isNeededForReflection(member)) {
      precompiledFunction.add(
          js('$className.prototype.$getterName.${namer.reflectableField} = 1'));
    }
  }

  void generateSetter(Element member, String fieldName, String accessorName,
                      ClassBuilder builder) {
    String setterName = namer.setterNameFromAccessorName(accessorName);
    ClassElement cls = member.getEnclosingClass();
    String className = namer.getNameOfClass(cls);
    String receiver = backend.isInterceptorClass(cls) ? 'receiver' : 'this';
    List<String> args =
        backend.isInterceptedMethod(member) ? ['receiver', 'v'] : ['v'];
    precompiledFunction.add(
        js('$className.prototype.$setterName = #',
           js.fun(args, js.return_(js('$receiver.$fieldName = v')))));
    if (backend.isNeededForReflection(member)) {
      precompiledFunction.add(
          js('$className.prototype.$setterName.${namer.reflectableField} = 1'));
    }
  }

  bool canGenerateCheckedSetter(VariableElement field) {
    // We never generate accessors for top-level/static fields.
    if (!field.isInstanceMember()) return false;
    DartType type = field.computeType(compiler).unalias(compiler);
    if (type.element.isTypeVariable() ||
        (type is FunctionType && type.containsTypeVariables) ||
        type.treatAsDynamic ||
        type.element == compiler.objectClass) {
      // TODO(ngeoffray): Support type checks on type parameters.
      return false;
    }
    return true;
  }

  void generateCheckedSetter(Element member,
                             String fieldName,
                             String accessorName,
                             ClassBuilder builder) {
    assert(canGenerateCheckedSetter(member));
    DartType type = member.computeType(compiler);
    // TODO(ahe): Generate a dynamic type error here.
    if (type.element.isErroneous()) return;
    type = type.unalias(compiler);
    // TODO(11273): Support complex subtype checks.
    type = type.asRaw();
    CheckedModeHelper helper =
        backend.getCheckedModeHelper(type, typeCast: false);
    FunctionElement helperElement = helper.getElement(compiler);
    String helperName = namer.isolateAccess(helperElement);
    List<jsAst.Expression> arguments = <jsAst.Expression>[js('v')];
    if (helperElement.computeSignature(compiler).parameterCount != 1) {
      arguments.add(js.string(namer.operatorIsType(type)));
    }

    String setterName = namer.setterNameFromAccessorName(accessorName);
    String receiver = backend.isInterceptorClass(member.getEnclosingClass())
        ? 'receiver' : 'this';
    List<String> args = backend.isInterceptedMethod(member)
        ? ['receiver', 'v']
        : ['v'];
    builder.addProperty(setterName,
        js.fun(args,
            js('$receiver.$fieldName = #', js(helperName)(arguments))));
    generateReflectionDataForFieldGetterOrSetter(
        member, setterName, builder, isGetter: false);
  }

  void emitClassConstructor(ClassElement classElement,
                            ClassBuilder builder,
                            String runtimeName) {
    List<String> fields = <String>[];
    if (!classElement.isNative()) {
      visitFields(classElement, false,
                  (Element member,
                   String name,
                   String accessorName,
                   bool needsGetter,
                   bool needsSetter,
                   bool needsCheckedSetter) {
        fields.add(name);
      });
    }
    String constructorName = namer.getNameOfClass(classElement);
    precompiledFunction.add(new jsAst.FunctionDeclaration(
        new jsAst.VariableDeclaration(constructorName),
        js.fun(fields, fields.map(
            (name) => js('this.$name = $name')).toList())));
    if (runtimeName == null) {
      runtimeName = constructorName;
    }
    precompiledFunction.addAll([
        js('$constructorName.builtin\$cls = "$runtimeName"'),
        js.if_('!"name" in $constructorName',
              js('$constructorName.name = "$constructorName"')),
        js('\$desc=\$collectedClasses.$constructorName'),
        js.if_('\$desc instanceof Array', js('\$desc = \$desc[1]')),
        js('$constructorName.prototype = \$desc'),
    ]);

    precompiledConstructorNames.add(js(constructorName));
  }

  jsAst.FunctionDeclaration buildPrecompiledFunction() {
    // TODO(ahe): Compute a hash code.
    String name = 'dart_precompiled';

    precompiledFunction.add(
        js.return_(
            new jsAst.ArrayInitializer.from(precompiledConstructorNames)));
    precompiledFunction.insert(0, js(r'var $desc'));
    return new jsAst.FunctionDeclaration(
        new jsAst.VariableDeclaration(name),
        js.fun([r'$collectedClasses'], precompiledFunction));
  }

  void emitSuper(String superName, ClassBuilder builder) {
    /* Do nothing. */
  }

  void emitRuntimeName(String runtimeName, ClassBuilder builder) {
    /* Do nothing. */
  }

  void recordMangledField(Element member,
                          String accessorName,
                          String memberName) {
    if (!backend.shouldRetainGetter(member)) return;
    String previousName;
    if (member.isInstanceMember()) {
      previousName = mangledFieldNames.putIfAbsent(
          '${namer.getterPrefix}$accessorName',
          () => memberName);
    } else {
      previousName = mangledGlobalFieldNames.putIfAbsent(
          accessorName,
          () => memberName);
    }
    assert(invariant(member, previousName == memberName,
                     message: '$previousName != ${memberName}'));
  }

  /// Returns `true` if fields added.
  bool emitFields(Element element,
                  ClassBuilder builder,
                  String superName,
                  { bool classIsNative: false,
                    bool emitStatics: false,
                    bool onlyForRti: false }) {
    assert(!emitStatics || !onlyForRti);
    bool isClass = false;
    bool isLibrary = false;
    if (element.isClass()) {
      isClass = true;
    } else if (element.isLibrary()) {
      isLibrary = false;
      assert(invariant(element, emitStatics));
    } else {
      throw new SpannableAssertionFailure(
          element, 'Must be a ClassElement or a LibraryElement');
    }
    StringBuffer buffer = new StringBuffer();
    if (emitStatics) {
      assert(invariant(element, superName == null, message: superName));
    } else {
      assert(invariant(element, superName != null));
      String nativeName =
          namer.getPrimitiveInterceptorRuntimeName(element);
      if (nativeName != null) {
        buffer.write('$nativeName/');
      }
      buffer.write('$superName;');
    }
    int bufferClassLength = buffer.length;

    String separator = '';

    var fieldMetadata = [];
    bool hasMetadata = false;

    if (!onlyForRti) {
      visitFields(element, emitStatics,
                  (VariableElement field,
                   String name,
                   String accessorName,
                   bool needsGetter,
                   bool needsSetter,
                   bool needsCheckedSetter) {
        // Ignore needsCheckedSetter - that is handled below.
        bool needsAccessor = (needsGetter || needsSetter);
        // We need to output the fields for non-native classes so we can auto-
        // generate the constructor.  For native classes there are no
        // constructors, so we don't need the fields unless we are generating
        // accessors at runtime.
        if (!classIsNative || needsAccessor) {
          buffer.write(separator);
          separator = ',';
          var metadata = buildMetadataFunction(field);
          if (metadata != null) {
            hasMetadata = true;
          } else {
            metadata = new jsAst.LiteralNull();
          }
          fieldMetadata.add(metadata);
          recordMangledField(field, accessorName, field.name.slowToString());
          if (!needsAccessor) {
            // Emit field for constructor generation.
            assert(!classIsNative);
            buffer.write(name);
          } else {
            // Emit (possibly renaming) field name so we can add accessors at
            // runtime.
            buffer.write(accessorName);
            if (name != accessorName) {
              buffer.write(':$name');
              // Only the native classes can have renaming accessors.
              assert(classIsNative);
            }

            int getterCode = 0;
            if (needsGetter) {
              if (field.isInstanceMember()) {
                // 01:  function() { return this.field; }
                // 10:  function(receiver) { return receiver.field; }
                // 11:  function(receiver) { return this.field; }
                bool isIntercepted = backend.fieldHasInterceptedGetter(field);
                getterCode += isIntercepted ? 2 : 0;
                getterCode += backend.isInterceptorClass(element) ? 0 : 1;
                // TODO(sra): 'isInterceptorClass' might not be the correct test
                // for methods forced to use the interceptor convention because
                // the method's class was elsewhere mixed-in to an interceptor.
                assert(!field.isInstanceMember() || getterCode != 0);
                if (isIntercepted) {
                  interceptorInvocationNames.add(namer.getterName(field));
                }
              } else {
                getterCode = 1;
              }
            }
            int setterCode = 0;
            if (needsSetter) {
              if (field.isInstanceMember()) {
                // 01:  function(value) { this.field = value; }
                // 10:  function(receiver, value) { receiver.field = value; }
                // 11:  function(receiver, value) { this.field = value; }
                bool isIntercepted = backend.fieldHasInterceptedSetter(field);
                setterCode += isIntercepted ? 2 : 0;
                setterCode += backend.isInterceptorClass(element) ? 0 : 1;
                assert(!field.isInstanceMember() || setterCode != 0);
                if (isIntercepted) {
                  interceptorInvocationNames.add(namer.setterName(field));
                }
              } else {
                setterCode = 1;
              }
            }
            int code = getterCode + (setterCode << 2);
            if (code == 0) {
              compiler.reportInternalError(
                  field, 'Internal error: code is 0 ($element/$field)');
            } else {
              buffer.write(FIELD_CODE_CHARACTERS[code - FIRST_FIELD_CODE]);
            }
          }
          if (backend.isAccessibleByReflection(field)) {
            buffer.write(new String.fromCharCode(REFLECTION_MARKER));
          }
        }
      });
    }

    bool fieldsAdded = buffer.length > bufferClassLength;
    String compactClassData = buffer.toString();
    jsAst.Expression classDataNode = js.string(compactClassData);
    if (hasMetadata) {
      fieldMetadata.insert(0, classDataNode);
      classDataNode = new jsAst.ArrayInitializer.from(fieldMetadata);
    }
    builder.addProperty('', classDataNode);
    return fieldsAdded;
  }

  void emitClassGettersSetters(ClassElement classElement,
                               ClassBuilder builder) {

    visitFields(classElement, false,
                (VariableElement member,
                 String name,
                 String accessorName,
                 bool needsGetter,
                 bool needsSetter,
                 bool needsCheckedSetter) {
      compiler.withCurrentElement(member, () {
        if (needsCheckedSetter) {
          assert(!needsSetter);
          generateCheckedSetter(member, name, accessorName, builder);
        }
        if (needsGetter) {
          generateGetter(member, name, accessorName, builder);
        }
        if (needsSetter) {
          generateSetter(member, name, accessorName, builder);
        }
      });
    });
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [classElement] must be a declaration element.
   */
  void generateClass(ClassElement classElement, CodeBuffer buffer) {
    final onlyForRti = rtiNeededClasses.contains(classElement);

    assert(invariant(classElement, classElement.isDeclaration));
    assert(invariant(classElement, !classElement.isNative() || onlyForRti));

    needsDefineClass = true;
    String className = namer.getNameOfClass(classElement);

    ClassElement superclass = classElement.superclass;
    String superName = "";
    if (superclass != null) {
      superName = namer.getNameOfClass(superclass);
    }
    String runtimeName =
        namer.getPrimitiveInterceptorRuntimeName(classElement);

    if (classElement.isMixinApplication) {
      String mixinName = namer.getNameOfClass(computeMixinClass(classElement));
      superName = '$superName+$mixinName';
      needsMixinSupport = true;
    }

    ClassBuilder builder = new ClassBuilder();
    emitClassConstructor(classElement, builder, runtimeName);
    emitSuper(superName, builder);
    emitRuntimeName(runtimeName, builder);
    emitFields(classElement, builder, superName, onlyForRti: onlyForRti);
    emitClassGettersSetters(classElement, builder);
    if (!classElement.isMixinApplication) {
      emitInstanceMembers(classElement, builder);
    }
    emitIsTests(classElement, builder);

    emitClassBuilderWithReflectionData(
        className, classElement, builder, buffer);
  }

  void emitClassBuilderWithReflectionData(String className,
                                          ClassElement classElement,
                                          ClassBuilder builder,
                                          CodeBuffer buffer) {
    var metadata = buildMetadataFunction(classElement);
    if (metadata != null) {
      builder.addProperty("@", metadata);
    }

    if (backend.isNeededForReflection(classElement)) {
      Link typeVars = classElement.typeVariables;
      List properties = [];
      for (TypeVariableType typeVar in typeVars) {
        properties.add(js.string(typeVar.name.slowToString()));
        properties.add(js.toExpression(reifyType(typeVar.element.bound)));
      }

      ClassElement superclass = classElement.superclass;
      bool hasSuper = superclass != null;
      if ((!properties.isEmpty && !hasSuper) ||
          (hasSuper && superclass.typeVariables != typeVars)) {
        builder.addProperty('<>', new jsAst.ArrayInitializer.from(properties));
      }
    }
    List<CodeBuffer> classBuffers = elementBuffers[classElement];
    if (classBuffers == null) {
      classBuffers = [];
    } else {
      elementBuffers.remove(classElement);
    }
    CodeBuffer statics = new CodeBuffer();
    statics.write('{$n');
    bool hasStatics = false;
    ClassBuilder staticsBuilder = new ClassBuilder();
    if (emitFields(classElement, staticsBuilder, null, emitStatics: true)) {
      hasStatics = true;
      statics.write('"":$_');
      statics.write(
          jsAst.prettyPrint(staticsBuilder.properties.single.value, compiler));
      statics.write(',$n');
    }
    for (CodeBuffer classBuffer in classBuffers) {
      // TODO(ahe): What about deferred?
      if (classBuffer != null) {
        hasStatics = true;
        statics.addBuffer(classBuffer);
      }
    }
    statics.write('}$n');
    if (hasStatics) {
      builder.addProperty('static', new jsAst.Blob(statics));
    }

    // TODO(ahe): This method (generateClass) should return a jsAst.Expression.
    if (!buffer.isEmpty) {
      buffer.write(',$n$n');
    }
    buffer.write('$className:$_');
    buffer.write(jsAst.prettyPrint(builder.toObjectInitializer(), compiler));
    String reflectionName = getReflectionName(classElement, className);
    if (reflectionName != null) {
      List<int> interfaces = <int>[];
      for (DartType interface in classElement.interfaces) {
        interfaces.add(reifyType(interface));
      }
      buffer.write(',$n$n"+$reflectionName": $interfaces');
    }
  }

  /// If this is true then we can generate the noSuchMethod handlers at startup
  /// time, instead of them being emitted as part of the Object class.
  bool get generateTrivialNsmHandlers => true;

  int _selectorRank(Selector selector) {
    int arity = selector.argumentCount * 3;
    if (selector.isGetter()) return arity + 2;
    if (selector.isSetter()) return arity + 1;
    return arity;
  }

  int _compareSelectorNames(Selector selector1, Selector selector2) {
    String name1 = selector1.name.toString();
    String name2 = selector2.name.toString();
    if (name1 != name2) return Comparable.compare(name1, name2);
    return _selectorRank(selector1) - _selectorRank(selector2);
  }

  /**
   * Returns a mapping containing all checked function types for which [type]
   * can be a subtype. A function type is mapped to [:true:] if [type] is
   * statically known to be a subtype of it and to [:false:] if [type] might
   * be a subtype, provided with the right type arguments.
   */
  // TODO(johnniwinther): Change to return a mapping from function types to
  // a set of variable points and use this to detect statically/dynamically
  // known subtype relations.
  Map<FunctionType, bool> getFunctionTypeChecksOn(DartType type) {
    Map<FunctionType, bool> functionTypeMap =
        new LinkedHashMap<FunctionType, bool>();
    for (FunctionType functionType in checkedFunctionTypes) {
      if (compiler.types.isSubtype(type, functionType)) {
        functionTypeMap[functionType] = true;
      } else if (compiler.types.isPotentialSubtype(type, functionType)) {
        functionTypeMap[functionType] = false;
      }
    }
    // TODO(johnniwinther): Ensure stable ordering of the keys.
    return functionTypeMap;
  }

  /**
   * Generate "is tests" for [cls]: itself, and the "is tests" for the
   * classes it implements and type argument substitution functions for these
   * tests.   We don't need to add the "is tests" of the super class because
   * they will be inherited at runtime, but we may need to generate the
   * substitutions, because they may have changed.
   */
  void generateIsTestsOn(ClassElement cls,
                         void emitIsTest(Element element),
                         FunctionTypeTestEmitter emitIsFunctionTypeTest,
                         FunctionTypeSignatureEmitter emitFunctionTypeSignature,
                         SubstitutionEmitter emitSubstitution) {
    if (checkedClasses.contains(cls)) {
      emitIsTest(cls);
      emitSubstitution(cls);
    }

    RuntimeTypes rti = backend.rti;
    ClassElement superclass = cls.superclass;

    bool haveSameTypeVariables(ClassElement a, ClassElement b) {
      if (a.isClosure()) return true;
      if (b.isUnnamedMixinApplication) {
        return false;
      }
      return a.typeVariables == b.typeVariables;
    }

    if (superclass != null && superclass != compiler.objectClass &&
        !haveSameTypeVariables(cls, superclass)) {
      // We cannot inherit the generated substitutions, because the type
      // variable layout for this class is different.  Instead we generate
      // substitutions for all checks and make emitSubstitution a NOP for the
      // rest of this function.
      Set<ClassElement> emitted = new Set<ClassElement>();
      // TODO(karlklose): move the computation of these checks to
      // RuntimeTypeInformation.
      if (backend.classNeedsRti(cls)) {
        emitSubstitution(superclass, emitNull: true);
        emitted.add(superclass);
      }
      for (DartType supertype in cls.allSupertypes) {
        ClassElement superclass = supertype.element;
        if (classesUsingTypeVariableTests.contains(superclass)) {
          emitSubstitution(superclass, emitNull: true);
          emitted.add(superclass);
        }
        for (ClassElement check in checkedClasses) {
          if (supertype.element == check && !emitted.contains(check)) {
            // Generate substitution.  If no substitution is necessary, emit
            // [:null:] to overwrite a (possibly) existing substitution from the
            // super classes.
            emitSubstitution(check, emitNull: true);
            emitted.add(check);
          }
        }
      }
      void emitNothing(_, {emitNull}) {};
      emitSubstitution = emitNothing;
    }

    Set<Element> generated = new Set<Element>();
    // A class that defines a [:call:] method implicitly implements
    // [Function] and needs checks for all typedefs that are used in is-checks.
    if (checkedClasses.contains(compiler.functionClass) ||
        !checkedFunctionTypes.isEmpty) {
      Element call = cls.lookupLocalMember(Compiler.CALL_OPERATOR_NAME);
      if (call == null) {
        // If [cls] is a closure, it has a synthetic call operator method.
        call = cls.lookupBackendMember(Compiler.CALL_OPERATOR_NAME);
      }
      if (call != null && call.isFunction()) {
        generateInterfacesIsTests(compiler.functionClass,
                                  emitIsTest,
                                  emitSubstitution,
                                  generated);
        FunctionType callType = call.computeType(compiler);
        Map<FunctionType, bool> functionTypeChecks =
            getFunctionTypeChecksOn(callType);
        generateFunctionTypeTests(call, callType, functionTypeChecks,
            emitFunctionTypeSignature, emitIsFunctionTypeTest);
     }
    }

    for (DartType interfaceType in cls.interfaces) {
      generateInterfacesIsTests(interfaceType.element, emitIsTest,
                                emitSubstitution, generated);
    }
  }

  /**
   * Generate "is tests" where [cls] is being implemented.
   */
  void generateInterfacesIsTests(ClassElement cls,
                                 void emitIsTest(ClassElement element),
                                 SubstitutionEmitter emitSubstitution,
                                 Set<Element> alreadyGenerated) {
    void tryEmitTest(ClassElement check) {
      if (!alreadyGenerated.contains(check) && checkedClasses.contains(check)) {
        alreadyGenerated.add(check);
        emitIsTest(check);
        emitSubstitution(check);
      }
    };

    tryEmitTest(cls);

    for (DartType interfaceType in cls.interfaces) {
      Element element = interfaceType.element;
      tryEmitTest(element);
      generateInterfacesIsTests(element, emitIsTest, emitSubstitution,
                                alreadyGenerated);
    }

    // We need to also emit "is checks" for the superclass and its supertypes.
    ClassElement superclass = cls.superclass;
    if (superclass != null) {
      tryEmitTest(superclass);
      generateInterfacesIsTests(superclass, emitIsTest, emitSubstitution,
                                alreadyGenerated);
    }
  }

  static const int MAX_FUNCTION_TYPE_PREDICATES = 10;

  /**
   * Generates function type checks on [method] with type [methodType] against
   * the function type checks in [functionTypeChecks].
   */
  void generateFunctionTypeTests(
      Element method,
      FunctionType methodType,
      Map<FunctionType, bool> functionTypeChecks,
      FunctionTypeSignatureEmitter emitFunctionTypeSignature,
      FunctionTypeTestEmitter emitIsFunctionTypeTest) {
    bool hasDynamicFunctionTypeCheck = false;
    int neededPredicates = 0;
    functionTypeChecks.forEach((FunctionType functionType, bool knownSubtype) {
      if (!knownSubtype) {
        registerDynamicFunctionTypeCheck(functionType);
        hasDynamicFunctionTypeCheck = true;
      } else if (!backend.rti.isSimpleFunctionType(functionType)) {
        // Simple function types are always checked using predicates and should
        // not provoke generation of signatures.
        neededPredicates++;
      }
    });
    bool alwaysUseSignature = false;
    if (hasDynamicFunctionTypeCheck ||
        neededPredicates > MAX_FUNCTION_TYPE_PREDICATES) {
      emitFunctionTypeSignature(method, methodType);
      alwaysUseSignature = true;
    }
    functionTypeChecks.forEach((FunctionType functionType, bool knownSubtype) {
      if (knownSubtype) {
        if (backend.rti.isSimpleFunctionType(functionType)) {
          // Simple function types are always checked using predicates.
          emitIsFunctionTypeTest(functionType);
        } else if (alwaysUseSignature) {
          registerDynamicFunctionTypeCheck(functionType);
        } else {
          emitIsFunctionTypeTest(functionType);
        }
      }
    });
  }

  /**
   * Return a function that returns true if its argument is a class
   * that needs to be emitted.
   */
  Function computeClassFilter() {
    if (backend.isTreeShakingDisabled) return (ClassElement cls) => true;

    Set<ClassElement> unneededClasses = new Set<ClassElement>();
    // The [Bool] class is not marked as abstract, but has a factory
    // constructor that always throws. We never need to emit it.
    unneededClasses.add(compiler.boolClass);

    // Go over specialized interceptors and then constants to know which
    // interceptors are needed.
    Set<ClassElement> needed = new Set<ClassElement>();
    backend.specializedGetInterceptors.forEach(
        (_, Iterable<ClassElement> elements) {
          needed.addAll(elements);
        }
    );

    // Add interceptors referenced by constants.
    needed.addAll(interceptorsReferencedFromConstants());

    // Add unneeded interceptors to the [unneededClasses] set.
    for (ClassElement interceptor in backend.interceptedClasses) {
      if (!needed.contains(interceptor)
          && interceptor != compiler.objectClass) {
        unneededClasses.add(interceptor);
      }
    }

    return (ClassElement cls) => !unneededClasses.contains(cls);
  }

  Set<ClassElement> interceptorsReferencedFromConstants() {
    Set<ClassElement> classes = new Set<ClassElement>();
    ConstantHandler handler = compiler.constantHandler;
    List<Constant> constants = handler.getConstantsForEmission();
    for (Constant constant in constants) {
      if (constant is InterceptorConstant) {
        InterceptorConstant interceptorConstant = constant;
        classes.add(interceptorConstant.dispatchedType.element);
      }
    }
    return classes;
  }

  void emitFinishClassesInvocationIfNecessary(CodeBuffer buffer) {
    if (needsDefineClass) {
      buffer.write('$finishClassesName($classesCollector,'
                   '$_$isolateProperties,'
                   '${_}null)$N');

      // Reset the map.
      buffer.write("$classesCollector$_=${_}null$N$n");
    }
  }

  void emitStaticFunctions(CodeBuffer eagerBuffer) {
    bool isStaticFunction(Element element) =>
        !element.isInstanceMember() && !element.isField();

    Iterable<Element> elements =
        backend.generatedCode.keys.where(isStaticFunction);
    Set<Element> pendingElementsWithBailouts =
        backend.generatedBailoutCode.keys
            .where(isStaticFunction)
            .toSet();

    for (Element element in Elements.sortedByPosition(elements)) {
      pendingElementsWithBailouts.remove(element);
      ClassBuilder builder = new ClassBuilder();
      containerBuilder.addMember(element, builder);
      builder.writeOn_DO_NOT_USE(
          bufferForElement(element, eagerBuffer), compiler, ',$n$n');
    }

    if (!pendingElementsWithBailouts.isEmpty) {
      addComment('pendingElementsWithBailouts', eagerBuffer);
    }
    // Is it possible the primary function was inlined but the bailout was not?
    for (Element element in
             Elements.sortedByPosition(pendingElementsWithBailouts)) {
      jsAst.Expression bailoutCode = backend.generatedBailoutCode[element];
      new ClassBuilder()
          ..addProperty(namer.getBailoutName(element), bailoutCode)
          ..writeOn_DO_NOT_USE(
              bufferForElement(element, eagerBuffer), compiler, ',$n$n');
    }
  }

  void emitStaticNonFinalFieldInitializations(CodeBuffer buffer) {
    ConstantHandler handler = compiler.constantHandler;
    Iterable<VariableElement> staticNonFinalFields =
        handler.getStaticNonFinalFieldsForEmission();
    for (Element element in Elements.sortedByPosition(staticNonFinalFields)) {
      // [:interceptedNames:] is handled in [emitInterceptedNames].
      if (element == backend.interceptedNames) continue;
      // `mapTypeToInterceptor` is handled in [emitMapTypeToInterceptor].
      if (element == backend.mapTypeToInterceptor) continue;
      compiler.withCurrentElement(element, () {
        Constant initialValue = handler.getInitialValueFor(element);
        jsAst.Expression init =
          js('$isolateProperties.${namer.getNameOfGlobalField(element)} = #',
              constantEmitter.referenceInInitializationContext(initialValue));
        buffer.write(jsAst.prettyPrint(init, compiler));
        buffer.write('$N');
      });
    }
  }

  void emitLazilyInitializedStaticFields(CodeBuffer buffer) {
    ConstantHandler handler = compiler.constantHandler;
    List<VariableElement> lazyFields =
        handler.getLazilyInitializedFieldsForEmission();
    if (!lazyFields.isEmpty) {
      needsLazyInitializer = true;
      for (VariableElement element in Elements.sortedByPosition(lazyFields)) {
        assert(backend.generatedBailoutCode[element] == null);
        jsAst.Expression code = backend.generatedCode[element];
        // The code is null if we ended up not needing the lazily
        // initialized field after all because of constant folding
        // before code generation.
        if (code == null) continue;
        // The code only computes the initial value. We build the lazy-check
        // here:
        //   lazyInitializer(prototype, 'name', fieldName, getterName, initial);
        // The name is used for error reporting. The 'initial' must be a
        // closure that constructs the initial value.
        List<jsAst.Expression> arguments = <jsAst.Expression>[];
        arguments.add(js(isolateProperties));
        arguments.add(js.string(element.name.slowToString()));
        arguments.add(js.string(namer.getNameX(element)));
        arguments.add(js.string(namer.getLazyInitializerName(element)));
        arguments.add(code);
        jsAst.Expression getter = buildLazyInitializedGetter(element);
        if (getter != null) {
          arguments.add(getter);
        }
        jsAst.Expression init = js(lazyInitializerName)(arguments);
        buffer.write(jsAst.prettyPrint(init, compiler));
        buffer.write("$N");
      }
    }
  }

  jsAst.Expression buildLazyInitializedGetter(VariableElement element) {
    // Nothing to do, the 'lazy' function will create the getter.
    return null;
  }

  void emitCompileTimeConstants(CodeBuffer eagerBuffer) {
    ConstantHandler handler = compiler.constantHandler;
    List<Constant> constants = handler.getConstantsForEmission(
        compareConstants);
    for (Constant constant in constants) {
      if (isConstantInlinedOrAlreadyEmitted(constant)) continue;
      String name = namer.constantName(constant);
      if (constant.isList()) emitMakeConstantListIfNotEmitted(eagerBuffer);
      CodeBuffer buffer = bufferForConstant(constant, eagerBuffer);
      jsAst.Expression init = js(
          '${namer.globalObjectForConstant(constant)}.$name = #',
          constantInitializerExpression(constant));
      buffer.write(jsAst.prettyPrint(init, compiler));
      buffer.write('$N');
    }
  }

  bool isConstantInlinedOrAlreadyEmitted(Constant constant) {
    if (constant.isFunction()) return true;   // Already emitted.
    if (constant.isPrimitive()) return true;  // Inlined.
    // The name is null when the constant is already a JS constant.
    // TODO(floitsch): every constant should be registered, so that we can
    // share the ones that take up too much space (like some strings).
    if (namer.constantName(constant) == null) return true;
    return false;
  }

  int compareConstants(Constant a, Constant b) {
    // Inlined constants don't affect the order and sometimes don't even have
    // names.
    int cmp1 = isConstantInlinedOrAlreadyEmitted(a) ? 0 : 1;
    int cmp2 = isConstantInlinedOrAlreadyEmitted(b) ? 0 : 1;
    if (cmp1 + cmp2 < 2) return cmp1 - cmp2;
    // Sorting by the long name clusters constants with the same constructor
    // which compresses a tiny bit better.
    int r = namer.constantLongName(a).compareTo(namer.constantLongName(b));
    if (r != 0) return r;
    // Resolve collisions in the long name by using the constant name (i.e. JS
    // name) which is unique.
    return namer.constantName(a).compareTo(namer.constantName(b));
  }

  void emitMakeConstantListIfNotEmitted(CodeBuffer buffer) {
    if (hasMakeConstantList) return;
    hasMakeConstantList = true;
    buffer
        ..write(namer.isolateName)
        ..write(r'''.makeConstantList = function(list) {
  list.immutable$list = true;
  list.fixed$length = true;
  return list;
};
''');
  }

  // Identify the noSuchMethod handlers that are so simple that we can
  // generate them programatically.
  bool isTrivialNsmHandler(
      int type, List argNames, Selector selector, String internalName) {
    if (!generateTrivialNsmHandlers) return false;
    // Check for interceptor calling convention.
    if (backend.isInterceptedName(selector.name)) {
      // We can handle the calling convention used by intercepted names in the
      // diff encoding, but we don't use that for non-minified code.
      if (!compiler.enableMinification) return false;
      String shortName = namer.invocationMirrorInternalName(selector);
      if (shortName.length > MAX_MINIFIED_LENGTH_FOR_DIFF_ENCODING) {
        return false;
      }
    }
    // Check for named arguments.
    if (argNames.length != 0) return false;
    // Check for unexpected name (this doesn't really happen).
    if (internalName.startsWith(namer.getterPrefix[0])) return type == 1;
    if (internalName.startsWith(namer.setterPrefix[0])) return type == 2;
    return type == 0;
  }

  void emitNoSuchMethodHandlers(DefineStubFunction defineStub) {
    // Do not generate no such method handlers if there is no class.
    if (compiler.codegenWorld.instantiatedClasses.isEmpty) return;

    String noSuchMethodName = namer.publicInstanceMethodNameByArity(
        Compiler.NO_SUCH_METHOD, Compiler.NO_SUCH_METHOD_ARG_COUNT);

    // Keep track of the JavaScript names we've already added so we
    // do not introduce duplicates (bad for code size).
    Map<String, Selector> addedJsNames = new Map<String, Selector>();

    void addNoSuchMethodHandlers(SourceString ignore, Set<Selector> selectors) {
      // Cache the object class and type.
      ClassElement objectClass = compiler.objectClass;
      DartType objectType = objectClass.computeType(compiler);

      for (Selector selector in selectors) {
        TypeMask mask = selector.mask;
        if (mask == null) {
          mask = new TypeMask.subclass(compiler.objectClass);
        }

        if (!mask.needsNoSuchMethodHandling(selector, compiler)) continue;
        String jsName = namer.invocationMirrorInternalName(selector);
        addedJsNames[jsName] = selector;
        String reflectionName = getReflectionName(selector, jsName);
        if (reflectionName != null) {
          mangledFieldNames[jsName] = reflectionName;
        }
      }
    }

    compiler.codegenWorld.invokedNames.forEach(addNoSuchMethodHandlers);
    compiler.codegenWorld.invokedGetters.forEach(addNoSuchMethodHandlers);
    compiler.codegenWorld.invokedSetters.forEach(addNoSuchMethodHandlers);

    // Set flag used by generateMethod helper below.  If we have very few
    // handlers we use defineStub for them all, rather than try to generate them
    // at runtime.
    bool haveVeryFewNoSuchMemberHandlers =
        (addedJsNames.length < VERY_FEW_NO_SUCH_METHOD_HANDLERS);

    jsAst.Expression generateMethod(String jsName, Selector selector) {
      // Values match JSInvocationMirror in js-helper library.
      int type = selector.invocationMirrorKind;
      List<jsAst.Parameter> parameters = <jsAst.Parameter>[];
      CodeBuffer args = new CodeBuffer();
      for (int i = 0; i < selector.argumentCount; i++) {
        parameters.add(new jsAst.Parameter('\$$i'));
      }

      List<jsAst.Expression> argNames =
          selector.getOrderedNamedArguments().map((SourceString name) =>
              js.string(name.slowToString())).toList();

      String methodName = selector.invocationMirrorMemberName;
      String internalName = namer.invocationMirrorInternalName(selector);
      String reflectionName = getReflectionName(selector, internalName);
      if (!haveVeryFewNoSuchMemberHandlers &&
          isTrivialNsmHandler(type, argNames, selector, internalName) &&
          reflectionName == null) {
        trivialNsmHandlers.add(selector);
        return null;
      }

      assert(backend.isInterceptedName(Compiler.NO_SUCH_METHOD));
      jsAst.Expression expression = js('this.$noSuchMethodName')(
          [js('this'),
           namer.elementAccess(backend.getCreateInvocationMirror())([
               js.string(compiler.enableMinification ?
                         internalName : methodName),
               js.string(internalName),
               type,
               new jsAst.ArrayInitializer.from(
                   parameters.map((param) => js(param.name)).toList()),
               new jsAst.ArrayInitializer.from(argNames)])]);
      parameters = backend.isInterceptedName(selector.name)
          ? ([new jsAst.Parameter('\$receiver')]..addAll(parameters))
          : parameters;
      return js.fun(parameters, js.return_(expression));
    }

    for (String jsName in addedJsNames.keys.toList()..sort()) {
      Selector selector = addedJsNames[jsName];
      jsAst.Expression method = generateMethod(jsName, selector);
      if (method != null) {
        defineStub(jsName, method);
        String reflectionName = getReflectionName(selector, jsName);
        if (reflectionName != null) {
          bool accessible = compiler.world.allFunctions.filter(selector).any(
              (Element e) => backend.isAccessibleByReflection(e));
          defineStub('+$reflectionName', js(accessible ? '1' : '0'));
        }
      }
    }
  }

  String buildIsolateSetup(CodeBuffer buffer,
                           Element appMain,
                           Element isolateMain) {
    String mainAccess = "${namer.isolateStaticClosureAccess(appMain)}";
    // Since we pass the closurized version of the main method to
    // the isolate method, we must make sure that it exists.
    return "${namer.isolateAccess(isolateMain)}($mainAccess)";
  }

  jsAst.Expression generateDispatchPropertyInitialization() {
    return js('!#', js.fun([], [
        js('var objectProto = Object.prototype'),
        js.for_('var i = 0', null, 'i++', [
            js('var property = "${generateDispatchPropertyName(0)}"'),
            js.if_('i > 0', js('property = rootProperty + "_" + i')),
            js.if_('!(property in  objectProto)',
                   js.return_(
                       js('init.dispatchPropertyName = property')))])])());
  }

  String generateDispatchPropertyName(int seed) {
    // TODO(sra): MD5 of contributing source code or URIs?
    return '___dart_dispatch_record_ZxYxX_${seed}_';
  }

  emitMain(CodeBuffer buffer) {
    if (compiler.isMockCompilation) return;
    Element main = compiler.mainApp.find(Compiler.MAIN);
    String mainCall = null;
    if (compiler.hasIsolateSupport()) {
      Element isolateMain =
        compiler.isolateHelperLibrary.find(Compiler.START_ROOT_ISOLATE);
      mainCall = buildIsolateSetup(buffer, main, isolateMain);
    } else {
      mainCall = '${namer.isolateAccess(main)}()';
    }
    if (backend.needToInitializeDispatchProperty) {
      buffer.write(
          jsAst.prettyPrint(generateDispatchPropertyInitialization(),
                            compiler));
      buffer.write(N);
    }
    addComment('BEGIN invoke [main].', buffer);
    // This code finds the currently executing script by listening to the
    // onload event of all script tags and getting the first script which
    // finishes. Since onload is called immediately after execution this should
    // not substantially change execution order.
    buffer.write('''
;(function (callback) {
  if (typeof document === "undefined") {
    callback(null);
    return;
  }
  if (document.currentScript) {
    callback(document.currentScript);
    return;
  }

  var scripts = document.scripts;
  function onLoad(event) {
    for (var i = 0; i < scripts.length; ++i) {
      scripts[i].removeEventListener("load", onLoad, false);
    }
    callback(event.target);
  }
  for (var i = 0; i < scripts.length; ++i) {
    scripts[i].addEventListener("load", onLoad, false);
  }
})(function(currentScript) {
  init.currentScript = currentScript;

  if (typeof dartMainRunner === "function") {
    dartMainRunner(function() { ${mainCall}; });
  } else {
    ${mainCall};
  }
})$N''');
    addComment('END invoke [main].', buffer);
  }

  void emitGetInterceptorMethod(CodeBuffer buffer,
                                String key,
                                Set<ClassElement> classes) {
    jsAst.Statement buildReturnInterceptor(ClassElement cls) {
      return js.return_(js(namer.isolateAccess(cls))['prototype']);
    }

    /**
     * Build a JavaScrit AST node for doing a type check on
     * [cls]. [cls] must be an interceptor class.
     */
    jsAst.Statement buildInterceptorCheck(ClassElement cls) {
      jsAst.Expression condition;
      assert(backend.isInterceptorClass(cls));
      if (cls == backend.jsBoolClass) {
        condition = js('(typeof receiver) == "boolean"');
      } else if (cls == backend.jsIntClass ||
                 cls == backend.jsDoubleClass ||
                 cls == backend.jsNumberClass) {
        throw 'internal error';
      } else if (cls == backend.jsArrayClass ||
                 cls == backend.jsMutableArrayClass ||
                 cls == backend.jsFixedArrayClass ||
                 cls == backend.jsExtendableArrayClass) {
        condition = js('receiver.constructor == Array');
      } else if (cls == backend.jsStringClass) {
        condition = js('(typeof receiver) == "string"');
      } else if (cls == backend.jsNullClass) {
        condition = js('receiver == null');
      } else {
        throw 'internal error';
      }
      return js.if_(condition, buildReturnInterceptor(cls));
    }

    bool hasArray = false;
    bool hasBool = false;
    bool hasDouble = false;
    bool hasInt = false;
    bool hasNull = false;
    bool hasNumber = false;
    bool hasString = false;
    bool hasNative = false;
    bool anyNativeClasses = compiler.enqueuer.codegen.nativeEnqueuer
          .hasInstantiatedNativeClasses();

    for (ClassElement cls in classes) {
      if (cls == backend.jsArrayClass ||
          cls == backend.jsMutableArrayClass ||
          cls == backend.jsFixedArrayClass ||
          cls == backend.jsExtendableArrayClass) hasArray = true;
      else if (cls == backend.jsBoolClass) hasBool = true;
      else if (cls == backend.jsDoubleClass) hasDouble = true;
      else if (cls == backend.jsIntClass) hasInt = true;
      else if (cls == backend.jsNullClass) hasNull = true;
      else if (cls == backend.jsNumberClass) hasNumber = true;
      else if (cls == backend.jsStringClass) hasString = true;
      else {
        // The set of classes includes classes mixed-in to interceptor classes
        // and user extensions of native classes.
        //
        // The set of classes also includes the 'primitive' interceptor
        // PlainJavaScriptObject even when it has not been resolved, since it is
        // only resolved through the reference in getNativeInterceptor when
        // getNativeInterceptor is marked as used.  Guard against probing
        // unresolved PlainJavaScriptObject by testing for anyNativeClasses.

        if (anyNativeClasses) {
          if (Elements.isNativeOrExtendsNative(cls)) hasNative = true;
        }
      }
    }
    if (hasDouble) {
      hasNumber = true;
    }
    if (hasInt) hasNumber = true;

    if (classes.containsAll(backend.interceptedClasses)) {
      // I.e. this is the general interceptor.
      hasNative = anyNativeClasses;
    }

    jsAst.Block block = new jsAst.Block.empty();

    if (hasNumber) {
      jsAst.Statement whenNumber;

      /// Note: there are two number classes in play: Dart's [num],
      /// and JavaScript's Number (typeof receiver == 'number').  This
      /// is the fallback used when we have determined that receiver
      /// is a JavaScript Number.
      jsAst.Return returnNumberClass = buildReturnInterceptor(
          hasDouble ? backend.jsDoubleClass : backend.jsNumberClass);

      if (hasInt) {
        jsAst.Expression isInt = js('Math.floor(receiver) == receiver');
        whenNumber = js.block([
            js.if_(isInt, buildReturnInterceptor(backend.jsIntClass)),
            returnNumberClass]);
      } else {
        whenNumber = returnNumberClass;
      }
      block.statements.add(
          js.if_('(typeof receiver) == "number"',
                 whenNumber));
    }

    if (hasString) {
      block.statements.add(buildInterceptorCheck(backend.jsStringClass));
    }
    if (hasNull) {
      block.statements.add(buildInterceptorCheck(backend.jsNullClass));
    } else {
      // Returning "undefined" or "null" here will provoke a JavaScript
      // TypeError which is later identified as a null-error by
      // [unwrapException] in js_helper.dart.
      block.statements.add(js.if_('receiver == null',
                                  js.return_(js('receiver'))));
    }
    if (hasBool) {
      block.statements.add(buildInterceptorCheck(backend.jsBoolClass));
    }
    // TODO(ahe): It might be faster to check for Array before
    // function and bool.
    if (hasArray) {
      block.statements.add(buildInterceptorCheck(backend.jsArrayClass));
    }

    if (hasNative) {
      block.statements.add(
          js.if_(
              js('(typeof receiver) != "object"'),
              js.return_(js('receiver'))));

      // if (receiver instanceof $.Object) return receiver;
      // return $.getNativeInterceptor(receiver);
      block.statements.add(
          js.if_(js('receiver instanceof #',
                    js(namer.isolateAccess(compiler.objectClass))),
                 js.return_(js('receiver'))));
      block.statements.add(
          js.return_(
              js(namer.isolateAccess(backend.getNativeInterceptorMethod))(
                  ['receiver'])));

    } else {
      ClassElement jsUnknown = backend.jsUnknownJavaScriptObjectClass;
      if (compiler.codegenWorld.instantiatedClasses.contains(jsUnknown)) {
        block.statements.add(
            js.if_(js('!(receiver instanceof #)',
                      js(namer.isolateAccess(compiler.objectClass))),
                   buildReturnInterceptor(jsUnknown)));
      }

      block.statements.add(js.return_(js('receiver')));
    }

    buffer.write(jsAst.prettyPrint(
        js('${namer.globalObjectFor(compiler.interceptorsLibrary)}.$key = #',
           js.fun(['receiver'], block)),
        compiler));
    buffer.write(N);
  }

  /**
   * Emit all versions of the [:getInterceptor:] method.
   */
  void emitGetInterceptorMethods(CodeBuffer buffer) {
    addComment('getInterceptor methods', buffer);
    Map<String, Set<ClassElement>> specializedGetInterceptors =
        backend.specializedGetInterceptors;
    for (String name in specializedGetInterceptors.keys.toList()..sort()) {
      Set<ClassElement> classes = specializedGetInterceptors[name];
      emitGetInterceptorMethod(buffer, name, classes);
    }
  }

  /**
   * Compute all the classes that must be emitted.
   */
  void computeNeededClasses() {
    instantiatedClasses =
        compiler.codegenWorld.instantiatedClasses.where(computeClassFilter())
            .toSet();

    void addClassWithSuperclasses(ClassElement cls) {
      neededClasses.add(cls);
      for (ClassElement superclass = cls.superclass;
          superclass != null;
          superclass = superclass.superclass) {
        neededClasses.add(superclass);
      }
    }

    void addClassesWithSuperclasses(Iterable<ClassElement> classes) {
      for (ClassElement cls in classes) {
        addClassWithSuperclasses(cls);
      }
    }

    // 1. We need to generate all classes that are instantiated.
    addClassesWithSuperclasses(instantiatedClasses);

    // 2. Add all classes used as mixins.
    Set<ClassElement> mixinClasses = neededClasses
        .where((ClassElement element) => element.isMixinApplication)
        .map(computeMixinClass)
        .toSet();
    neededClasses.addAll(mixinClasses);

    // 3. If we need noSuchMethod support, we run through all needed
    // classes to figure out if we need the support on any native
    // class. If so, we let the native emitter deal with it.
    if (compiler.enabledNoSuchMethod) {
      SourceString noSuchMethodName = Compiler.NO_SUCH_METHOD;
      Selector noSuchMethodSelector = compiler.noSuchMethodSelector;
      for (ClassElement element in neededClasses) {
        if (!element.isNative()) continue;
        Element member = element.lookupLocalMember(noSuchMethodName);
        if (member == null) continue;
        if (noSuchMethodSelector.applies(member, compiler)) {
          nativeEmitter.handleNoSuchMethod = true;
          break;
        }
      }
    }

    // 4. Find all classes needed for rti.
    // It is important that this is the penultimate step, at this point,
    // neededClasses must only contain classes that have been resolved and
    // codegen'd. The rtiNeededClasses may contain additional classes, but
    // these are thought to not have been instantiated, so we neeed to be able
    // to identify them later and make sure we only emit "empty shells" without
    // fields, etc.
    computeRtiNeededClasses();
    rtiNeededClasses.removeAll(neededClasses);
    // rtiNeededClasses now contains only the "empty shells".
    neededClasses.addAll(rtiNeededClasses);

    // 5. Finally, sort the classes.
    List<ClassElement> sortedClasses = Elements.sortedByPosition(neededClasses);

    for (ClassElement element in sortedClasses) {
      if (rtiNeededClasses.contains(element)) {
        regularClasses.add(element);
      } else if (Elements.isNativeOrExtendsNative(element)) {
        // For now, native classes and related classes cannot be deferred.
        nativeClasses.add(element);
        if (!element.isNative()) {
          assert(invariant(element, !isDeferred(element)));
          regularClasses.add(element);
        }
      } else if (isDeferred(element)) {
        deferredClasses.add(element);
      } else {
        regularClasses.add(element);
      }
    }
  }

  Set<ClassElement> computeRtiNeededClasses() {
    void addClassWithSuperclasses(ClassElement cls) {
      rtiNeededClasses.add(cls);
      for (ClassElement superclass = cls.superclass;
          superclass != null;
          superclass = superclass.superclass) {
        rtiNeededClasses.add(superclass);
      }
    }

    void addClassesWithSuperclasses(Iterable<ClassElement> classes) {
      for (ClassElement cls in classes) {
        addClassWithSuperclasses(cls);
      }
    }

    // 1.  Add classes that are referenced by type arguments or substitutions in
    //     argument checks.
    // TODO(karlklose): merge this case with 2 when unifying argument and
    // object checks.
    RuntimeTypes rti = backend.rti;
    rti.getRequiredArgumentClasses(backend).forEach((ClassElement c) {
      // Types that we represent with JS native types (like int and String) do
      // not need a class definition as we use the interceptor classes instead.
      if (!rti.isJsNative(c)) {
        addClassWithSuperclasses(c);
      }
    });

    // 2.  Add classes that are referenced by substitutions in object checks and
    //     their superclasses.
    TypeChecks requiredChecks =
        rti.computeChecks(rtiNeededClasses, checkedClasses);
    Set<ClassElement> classesUsedInSubstitutions =
        rti.getClassesUsedInSubstitutions(backend, requiredChecks);
    addClassesWithSuperclasses(classesUsedInSubstitutions);

    // 3.  Add classes that contain checked generic function types. These are
    //     needed to store the signature encoding.
    for (FunctionType type in checkedFunctionTypes) {
      ClassElement contextClass = Types.getClassContext(type);
      if (contextClass != null) {
        rtiNeededClasses.add(contextClass);
      }
    }

    return rtiNeededClasses;
  }

  // Returns a statement that takes care of performance critical
  // common case for a one-shot interceptor, or null if there is no
  // fast path.
  jsAst.Statement fastPathForOneShotInterceptor(Selector selector,
                                                Set<ClassElement> classes) {
    jsAst.Expression isNumber(String variable) {
      return js('typeof $variable == "number"');
    }

    jsAst.Expression isNotObject(String variable) {
      return js('typeof $variable != "object"');
    }

    jsAst.Expression isInt(String variable) {
      return isNumber(variable).binary('&&',
          js('Math.floor($variable) == $variable'));
    }

    jsAst.Expression tripleShiftZero(jsAst.Expression receiver) {
      return receiver.binary('>>>', js('0'));
    }

    if (selector.isOperator()) {
      String name = selector.name.stringValue;
      if (name == '==') {
        // Unfolds to:
        //    if (receiver == null) return a0 == null;
        //    if (typeof receiver != 'object') {
        //      return a0 != null && receiver === a0;
        //    }
        List<jsAst.Statement> body = <jsAst.Statement>[];
        body.add(js.if_('receiver == null', js.return_(js('a0 == null'))));
        body.add(js.if_(
            isNotObject('receiver'),
            js.return_(js('a0 != null && receiver === a0'))));
        return new jsAst.Block(body);
      }
      if (!classes.contains(backend.jsIntClass)
          && !classes.contains(backend.jsNumberClass)
          && !classes.contains(backend.jsDoubleClass)) {
        return null;
      }
      if (selector.argumentCount == 1) {
        // The following operators do not map to a JavaScript
        // operator.
        if (name == '~/' || name == '<<' || name == '%' || name == '>>') {
          return null;
        }
        jsAst.Expression result = js('receiver').binary(name, js('a0'));
        if (name == '&' || name == '|' || name == '^') {
          result = tripleShiftZero(result);
        }
        // Unfolds to:
        //    if (typeof receiver == "number" && typeof a0 == "number")
        //      return receiver op a0;
        return js.if_(
            isNumber('receiver').binary('&&', isNumber('a0')),
            js.return_(result));
      } else if (name == 'unary-') {
        // [: if (typeof receiver == "number") return -receiver :].
        return js.if_(isNumber('receiver'),
                      js.return_(js('-receiver')));
      } else {
        assert(name == '~');
        return js.if_(isInt('receiver'),
                      js.return_(js('~receiver >>> 0')));
      }
    } else if (selector.isIndex() || selector.isIndexSet()) {
      // For an index operation, this code generates:
      //
      //    if (receiver.constructor == Array || typeof receiver == "string") {
      //      if (a0 >>> 0 === a0 && a0 < receiver.length) {
      //        return receiver[a0];
      //      }
      //    }
      //
      // For an index set operation, this code generates:
      //
      //    if (receiver.constructor == Array && !receiver.immutable$list) {
      //      if (a0 >>> 0 === a0 && a0 < receiver.length) {
      //        return receiver[a0] = a1;
      //      }
      //    }
      bool containsArray = classes.contains(backend.jsArrayClass);
      bool containsString = classes.contains(backend.jsStringClass);
      bool containsJsIndexable = classes.any((cls) {
        return compiler.world.isSubtype(
            backend.jsIndexingBehaviorInterface, cls);
      });
      // The index set operator requires a check on its set value in
      // checked mode, so we don't optimize the interceptor if the
      // compiler has type assertions enabled.
      if (selector.isIndexSet()
          && (compiler.enableTypeAssertions || !containsArray)) {
        return null;
      }
      if (!containsArray && !containsString) {
        return null;
      }
      jsAst.Expression isIntAndAboveZero = js('a0 >>> 0 === a0');
      jsAst.Expression belowLength = js('a0 < receiver.length');
      jsAst.Expression arrayCheck = js('receiver.constructor == Array');
      jsAst.Expression indexableCheck =
          backend.generateIsJsIndexableCall(js('receiver'), js('receiver'));

      jsAst.Expression orExp(left, right) {
        return left == null ? right : left.binary('||', right);
      }

      if (selector.isIndex()) {
        jsAst.Expression stringCheck = js('typeof receiver == "string"');
        jsAst.Expression typeCheck;
        if (containsArray) {
          typeCheck = arrayCheck;
        }

        if (containsString) {
          typeCheck = orExp(typeCheck, stringCheck);
        }

        if (containsJsIndexable) {
          typeCheck = orExp(typeCheck, indexableCheck);
        }

        return js.if_(typeCheck,
                      js.if_(isIntAndAboveZero.binary('&&', belowLength),
                             js.return_(js('receiver[a0]'))));
      } else {
        jsAst.Expression typeCheck;
        if (containsArray) {
          typeCheck = arrayCheck;
        }

        if (containsJsIndexable) {
          typeCheck = orExp(typeCheck, indexableCheck);
        }

        jsAst.Expression isImmutableArray = typeCheck.binary(
            '&&', js(r'!receiver.immutable$list'));
        return js.if_(isImmutableArray.binary(
                      '&&', isIntAndAboveZero.binary('&&', belowLength)),
                      js.return_(js('receiver[a0] = a1')));
      }
    }
    return null;
  }

  void emitOneShotInterceptors(CodeBuffer buffer) {
    List<String> names = backend.oneShotInterceptors.keys.toList();
    names.sort();
    for (String name in names) {
      Selector selector = backend.oneShotInterceptors[name];
      Set<ClassElement> classes =
          backend.getInterceptedClassesOn(selector.name);
      String getInterceptorName =
          namer.getInterceptorName(backend.getInterceptorMethod, classes);

      List<jsAst.Parameter> parameters = <jsAst.Parameter>[];
      List<jsAst.Expression> arguments = <jsAst.Expression>[];
      parameters.add(new jsAst.Parameter('receiver'));
      arguments.add(js('receiver'));

      if (selector.isSetter()) {
        parameters.add(new jsAst.Parameter('value'));
        arguments.add(js('value'));
      } else {
        for (int i = 0; i < selector.argumentCount; i++) {
          String argName = 'a$i';
          parameters.add(new jsAst.Parameter(argName));
          arguments.add(js(argName));
        }
      }

      List<jsAst.Statement> body = <jsAst.Statement>[];
      jsAst.Statement optimizedPath =
          fastPathForOneShotInterceptor(selector, classes);
      if (optimizedPath != null) {
        body.add(optimizedPath);
      }

      String invocationName = backend.namer.invocationName(selector);
      String globalObject = namer.globalObjectFor(compiler.interceptorsLibrary);
      body.add(js.return_(
          js(globalObject)[getInterceptorName]('receiver')[invocationName](
              arguments)));

      jsAst.Expression assignment =
          js('${globalObject}.$name = #', js.fun(parameters, body));

      buffer.write(jsAst.prettyPrint(assignment, compiler));
      buffer.write(N);
    }
  }

  /**
   * If [JSInvocationMirror._invokeOn] has been compiled, emit all the
   * possible selector names that are intercepted into the
   * [interceptedNames] top-level variable. The implementation of
   * [_invokeOn] will use it to determine whether it should call the
   * method with an extra parameter.
   */
  void emitInterceptedNames(CodeBuffer buffer) {
    // TODO(ahe): We should not generate the list of intercepted names at
    // compile time, it can be generated automatically at runtime given
    // subclasses of Interceptor (which can easily be identified).
    if (!compiler.enabledInvokeOn) return;

    // TODO(ahe): We should roll this into
    // [emitStaticNonFinalFieldInitializations].
    String name = backend.namer.getNameOfGlobalField(backend.interceptedNames);

    int index = 0;
    var invocationNames = interceptorInvocationNames.toList()..sort();
    List<jsAst.ArrayElement> elements = invocationNames.map(
      (String invocationName) {
        jsAst.Literal str = js.string(invocationName);
        return new jsAst.ArrayElement(index++, str);
      }).toList();
    jsAst.ArrayInitializer array =
        new jsAst.ArrayInitializer(invocationNames.length, elements);

    jsAst.Expression assignment = js('$isolateProperties.$name = #', array);

    buffer.write(jsAst.prettyPrint(assignment, compiler));
    buffer.write(N);
  }

  /**
   * Emit initializer for [mapTypeToInterceptor] data structure used by
   * [findInterceptorForType].  See declaration of [mapTypeToInterceptor] in
   * `interceptors.dart`.
   */
  void emitMapTypeToInterceptor(CodeBuffer buffer) {
    // TODO(sra): Perhaps inject a constant instead?
    // TODO(sra): Filter by subclasses of native types.
    List<jsAst.Expression> elements = <jsAst.Expression>[];
    ConstantHandler handler = compiler.constantHandler;
    List<Constant> constants = handler.getConstantsForEmission();
    for (Constant constant in constants) {
      if (constant is TypeConstant) {
        TypeConstant typeConstant = constant;
        Element element = typeConstant.representedType.element;
        if (element is ClassElement) {
          ClassElement classElement = element;
          elements.add(backend.emitter.constantReference(constant));
          elements.add(js(namer.isolateAccess(classElement)));
        }
      }
    }

    jsAst.ArrayInitializer array = new jsAst.ArrayInitializer.from(elements);
    String name =
        backend.namer.getNameOfGlobalField(backend.mapTypeToInterceptor);
    jsAst.Expression assignment = js('$isolateProperties.$name = #', array);

    buffer.write(jsAst.prettyPrint(assignment, compiler));
    buffer.write(N);
  }

  void emitInitFunction(CodeBuffer buffer) {
    jsAst.Fun fun = js.fun([], [
      js('$isolateProperties = {}'),
    ]
    ..addAll(buildDefineClassAndFinishClassFunctionsIfNecessary())
    ..addAll(buildLazyInitializerFunctionIfNecessary())
    ..addAll(buildFinishIsolateConstructor())
    );
    jsAst.FunctionDeclaration decl = new jsAst.FunctionDeclaration(
        new jsAst.VariableDeclaration('init'), fun);
    buffer.write(jsAst.prettyPrint(decl, compiler).getText());
    if (compiler.enableMinification) buffer.write('\n');
  }

  /// The metadata function returns the metadata associated with
  /// [element] in generated code.  The metadata needs to be wrapped
  /// in a function as it refers to constants that may not have been
  /// constructed yet.  For example, a class is allowed to be
  /// annotated with itself.  The metadata function is used by
  /// mirrors_patch to implement DeclarationMirror.metadata.
  jsAst.Fun buildMetadataFunction(Element element) {
    if (!backend.retainMetadataOf(element)) return null;
    return compiler.withCurrentElement(element, () {
      var metadata = [];
      Link link = element.metadata;
      // TODO(ahe): Why is metadata sometimes null?
      if (link != null) {
        for (; !link.isEmpty; link = link.tail) {
          MetadataAnnotation annotation = link.head;
          Constant value = annotation.value;
          if (value == null) {
            compiler.reportInternalError(
                annotation, 'Internal error: value is null');
          } else {
            metadata.add(constantReference(value));
          }
        }
      }
      if (metadata.isEmpty) return null;
      return js.fun(
          [], [js.return_(new jsAst.ArrayInitializer.from(metadata))]);
    });
  }

  jsAst.Node reifyDefaultArguments(FunctionElement function) {
    FunctionSignature signature = function.computeSignature(compiler);
    if (signature.optionalParameterCount == 0) return null;
    List<int> defaultValues = <int>[];
    for (Element element in signature.orderedOptionalParameters) {
      Constant value =
          compiler.constantHandler.initialVariableValues[element];
      String stringRepresentation = (value == null) ? "null"
          : jsAst.prettyPrint(constantReference(value), compiler).getText();
      defaultValues.add(addGlobalMetadata(stringRepresentation));
    }
    return js.toExpression(defaultValues);
  }

  int reifyMetadata(MetadataAnnotation annotation) {
    Constant value = annotation.value;
    if (value == null) {
      compiler.reportInternalError(
          annotation, 'Internal error: value is null');
      return -1;
    }
    return addGlobalMetadata(
        jsAst.prettyPrint(constantReference(value), compiler).getText());
  }

  int reifyType(DartType type) {
    // TODO(ahe): Handle type variables correctly instead of using "#".
    String representation = backend.rti.getTypeRepresentation(type, (_) {});
    return addGlobalMetadata(representation.replaceAll('#', 'null'));
  }

  int reifyName(SourceString name) {
    return addGlobalMetadata('"${name.slowToString()}"');
  }

  int addGlobalMetadata(String string) {
    return globalMetadataMap.putIfAbsent(string, () {
      globalMetadata.add(string);
      return globalMetadata.length - 1;
    });
  }

  void emitMetadata(CodeBuffer buffer) {
    var literals = backend.typedefTypeLiterals.toList();
    Elements.sortedByPosition(literals);
    var properties = [];
    for (TypedefElement literal in literals) {
      var key = namer.getNameX(literal);
      var value = js.toExpression(reifyType(literal.rawType));
      properties.add(new jsAst.Property(js.string(key), value));
    }
    var map = new jsAst.ObjectInitializer(properties);
    buffer.write(
        jsAst.prettyPrint(
            js('init.functionAliases = #', map).toStatement(), compiler));
    buffer.write('${N}init.metadata$_=$_[');
    for (var metadata in globalMetadata) {
      if (metadata is String) {
        if (metadata != 'null') {
          buffer.write(metadata);
        }
      } else {
        throw 'Unexpected value in metadata: ${Error.safeToString(metadata)}';
      }
      buffer.write(',$n');
    }
    buffer.write('];$n');
  }

  void emitConvertToFastObjectFunction() {
    // Create an instance that uses 'properties' as prototype. This should make
    // 'properties' a fast object.
    mainBuffer.add(r'''function convertToFastObject(properties) {
  function MyClass() {};
  MyClass.prototype = properties;
  new MyClass();
''');
    if (DEBUG_FAST_OBJECTS) {
      ClassElement primitives =
          compiler.findHelper(const SourceString('Primitives'));
      FunctionElement printHelper =
          compiler.lookupElementIn(
              primitives, const SourceString('printString'));
      String printHelperName = namer.isolateAccess(printHelper);
      mainBuffer.add('''
// The following only works on V8 when run with option "--allow-natives-syntax".
if (typeof $printHelperName === "function") {
  $printHelperName("Size of global object: "
                   + String(Object.getOwnPropertyNames(properties).length)
                   + ", fast properties " + %HasFastProperties(properties));
}
''');
    }
mainBuffer.add(r'''
  return properties;
}
''');
  }


  String assembleProgram() {
    measure(() {
      // Compute the required type checks to know which classes need a
      // 'is$' method.
      computeRequiredTypeChecks();

      computeNeededClasses();

      mainBuffer.add(buildGeneratedBy());
      addComment(HOOKS_API_USAGE, mainBuffer);

      if (!areAnyElementsDeferred) {
        mainBuffer.add('(function(${namer.CURRENT_ISOLATE})$_{$n');
      }

      for (String globalObject in Namer.reservedGlobalObjectNames) {
        // The global objects start as so-called "slow objects". For V8, this
        // means that it won't try to make map transitions as we add properties
        // to these objects. Later on, we attempt to turn these objects into
        // fast objects by calling "convertToFastObject" (see
        // [emitConvertToFastObjectFunction]).
        mainBuffer
            ..write('var ${globalObject}$_=$_{}$N')
            ..write('delete ${globalObject}.x$N');
      }

      mainBuffer.add('function ${namer.isolateName}()$_{}\n');
      mainBuffer.add('init()$N$n');
      // Shorten the code by using [namer.CURRENT_ISOLATE] as temporary.
      isolateProperties = namer.CURRENT_ISOLATE;
      mainBuffer.add(
          '$isolateProperties$_=$_$isolatePropertiesName$N');

      emitStaticFunctions(mainBuffer);

      if (!regularClasses.isEmpty ||
          !deferredClasses.isEmpty ||
          !nativeClasses.isEmpty ||
          !compiler.codegenWorld.staticFunctionsNeedingGetter.isEmpty) {
        // Shorten the code by using "$$" as temporary.
        classesCollector = r"$$";
        mainBuffer.add('var $classesCollector$_=$_{}$N$n');
      }

      // As a side-effect, emitting classes will produce "bound closures" in
      // [methodClosures].  The bound closures are JS AST nodes that add
      // properties to $$ [classesCollector].  The bound closures are not
      // emitted until we have emitted all other classes (native or not).

      // Might create methodClosures.
      if (!regularClasses.isEmpty) {
        for (ClassElement element in regularClasses) {
          generateClass(element, bufferForElement(element, mainBuffer));
        }
      }

      // Emit native classes on [nativeBuffer].
      // Might create methodClosures.
      final CodeBuffer nativeBuffer = new CodeBuffer();
      if (!nativeClasses.isEmpty) {
        addComment('Native classes', nativeBuffer);
        addComment('Native classes', mainBuffer);
        nativeEmitter.generateNativeClasses(nativeClasses, mainBuffer);
      }
      nativeEmitter.finishGenerateNativeClasses();
      nativeEmitter.assembleCode(nativeBuffer);

      // Might create methodClosures.
      if (!deferredClasses.isEmpty) {
        for (ClassElement element in deferredClasses) {
          generateClass(element, bufferForElement(element, mainBuffer));
        }
      }

      containerBuilder.emitStaticFunctionClosures();

      addComment('Method closures', mainBuffer);
      // Now that we have emitted all classes, we know all the method
      // closures that will be needed.
      containerBuilder.methodClosures.forEach((String code, Element closure) {
        // TODO(ahe): Some of these can be deferred.
        String mangledName = namer.getNameOfClass(closure);
        mainBuffer.add('$classesCollector.$mangledName$_=$_'
             '[${namer.globalObjectFor(closure)},$_$code]');
        mainBuffer.add("$N$n");
      });

      // After this assignment we will produce invalid JavaScript code if we use
      // the classesCollector variable.
      classesCollector = 'classesCollector should not be used from now on';

      if (!elementBuffers.isEmpty) {
        var oldClassesCollector = classesCollector;
        classesCollector = r"$$";
        if (compiler.enableMinification) {
          mainBuffer.write(';');
        }

        for (Element element in elementBuffers.keys) {
          // TODO(ahe): Should iterate over all libraries.  Otherwise, we will
          // not see libraries that only have fields.
          if (element.isLibrary()) {
            LibraryElement library = element;
            ClassBuilder builder = new ClassBuilder();
            if (emitFields(library, builder, null, emitStatics: true)) {
              List<CodeBuffer> buffers = elementBuffers[library];
              var buffer = buffers[0];
              if (buffer == null) {
                buffers[0] = buffer = new CodeBuffer();
              }
              for (jsAst.Property property in builder.properties) {
                if (!buffer.isEmpty) buffer.write(',$n');
                buffer.addBuffer(jsAst.prettyPrint(property, compiler));
              }
            }
          }
        }

        if (!mangledFieldNames.isEmpty) {
          var keys = mangledFieldNames.keys.toList();
          keys.sort();
          var properties = [];
          for (String key in keys) {
            var value = js.string('${mangledFieldNames[key]}');
            properties.add(new jsAst.Property(js.string(key), value));
          }
          var map = new jsAst.ObjectInitializer(properties);
          mainBuffer.write(
              jsAst.prettyPrint(
                  js('init.mangledNames = #', map).toStatement(), compiler));
          if (compiler.enableMinification) {
            mainBuffer.write(';');
          }
        }
        if (!mangledGlobalFieldNames.isEmpty) {
          var keys = mangledGlobalFieldNames.keys.toList();
          keys.sort();
          var properties = [];
          for (String key in keys) {
            var value = js.string('${mangledGlobalFieldNames[key]}');
            properties.add(new jsAst.Property(js.string(key), value));
          }
          var map = new jsAst.ObjectInitializer(properties);
          mainBuffer.write(
              jsAst.prettyPrint(
                  js('init.mangledGlobalNames = #', map).toStatement(),
                  compiler));
          if (compiler.enableMinification) {
            mainBuffer.write(';');
          }
        }
        mainBuffer
            ..write(getReflectionDataParser(classesCollector, namer))
            ..write('([$n');

        List<Element> sortedElements =
            Elements.sortedByPosition(elementBuffers.keys);
        bool hasPendingStatics = false;
        for (Element element in sortedElements) {
          if (!element.isLibrary()) {
            for (CodeBuffer b in elementBuffers[element]) {
              if (b != null) {
                hasPendingStatics = true;
                compiler.reportInfo(
                    element, MessageKind.GENERIC, {'text': 'Pending statics.'});
                print(b.getText());
              }
            }
            continue;
          }
          LibraryElement library = element;
          List<CodeBuffer> buffers = elementBuffers[library];
          var buffer = buffers[0];
          var uri = library.canonicalUri;
          if (uri.scheme == 'file' && compiler.sourceMapUri != null) {
            // TODO(ahe): It is a hack to use compiler.sourceMapUri
            // here.  It should be relative to the main JavaScript
            // output file.
            uri = relativize(
                compiler.sourceMapUri, library.canonicalUri, false);
          }
          if (buffer != null) {
            var metadata = buildMetadataFunction(library);
            mainBuffer
                ..write('["${library.getLibraryOrScriptName()}",$_')
                ..write('"${uri}",$_')
                ..write(metadata == null
                        ? "" : jsAst.prettyPrint(metadata, compiler))
                ..write(',$_')
                ..write(namer.globalObjectFor(library))
                ..write(',$_')
                ..write('{$n')
                ..addBuffer(buffer)
                ..write('}');
            if (library == compiler.mainApp) {
              mainBuffer.write(',${n}1');
            }
            mainBuffer.write('],$n');
          }
          buffer = buffers[1];
          if (buffer != null) {
            deferredLibraries
                ..write('["${library.getLibraryOrScriptName()}",$_')
                ..write('"${uri}",$_')
                ..write('[],$_')
                ..write(namer.globalObjectFor(library))
                ..write(',$_')
                ..write('{$n')
                ..addBuffer(buffer)
                ..write('}],$n');
          }
          elementBuffers[library] = const [];
        }
        if (hasPendingStatics) {
          compiler.internalError('Pending statics (see above).');
        }
        mainBuffer.write('])$N');

        emitFinishClassesInvocationIfNecessary(mainBuffer);
        classesCollector = oldClassesCollector;
      }

      containerBuilder.emitStaticFunctionGetters(mainBuffer);

      emitRuntimeTypeSupport(mainBuffer);
      emitGetInterceptorMethods(mainBuffer);
      // Constants in checked mode call into RTI code to set type information
      // which may need getInterceptor methods, so we have to make sure that
      // [emitGetInterceptorMethods] has been called.
      emitCompileTimeConstants(mainBuffer);
      // Static field initializations require the classes and compile-time
      // constants to be set up.
      emitStaticNonFinalFieldInitializations(mainBuffer);
      emitOneShotInterceptors(mainBuffer);
      emitInterceptedNames(mainBuffer);
      emitMapTypeToInterceptor(mainBuffer);
      emitLazilyInitializedStaticFields(mainBuffer);

      mainBuffer.add(nativeBuffer);

      emitMetadata(mainBuffer);

      isolateProperties = isolatePropertiesName;
      // The following code should not use the short-hand for the
      // initialStatics.
      mainBuffer.add('${namer.CURRENT_ISOLATE}$_=${_}null$N');

      emitFinishIsolateConstructorInvocation(mainBuffer);
      mainBuffer.add(
          '${namer.CURRENT_ISOLATE}$_=${_}new ${namer.isolateName}()$N');

      emitConvertToFastObjectFunction();
      for (String globalObject in Namer.reservedGlobalObjectNames) {
        mainBuffer.add('$globalObject = convertToFastObject($globalObject)$N');
      }
      if (DEBUG_FAST_OBJECTS) {
        ClassElement primitives =
            compiler.findHelper(const SourceString('Primitives'));
        FunctionElement printHelper =
            compiler.lookupElementIn(
                primitives, const SourceString('printString'));
        String printHelperName = namer.isolateAccess(printHelper);

        mainBuffer.add('''
// The following only works on V8 when run with option "--allow-natives-syntax".
if (typeof $printHelperName === "function") {
  $printHelperName("Size of global helper object: "
                   + String(Object.getOwnPropertyNames(H).length)
                   + ", fast properties " + %HasFastProperties(H));
  $printHelperName("Size of global platform object: "
                   + String(Object.getOwnPropertyNames(P).length)
                   + ", fast properties " + %HasFastProperties(P));
  $printHelperName("Size of global dart:html object: "
                   + String(Object.getOwnPropertyNames(W).length)
                   + ", fast properties " + %HasFastProperties(W));
  $printHelperName("Size of isolate properties object: "
                   + String(Object.getOwnPropertyNames(\$).length)
                   + ", fast properties " + %HasFastProperties(\$));
  $printHelperName("Size of constant object: "
                   + String(Object.getOwnPropertyNames(C).length)
                   + ", fast properties " + %HasFastProperties(C));
  var names = Object.getOwnPropertyNames(\$);
  for (var i = 0; i < names.length; i++) {
    $printHelperName("\$." + names[i]);
  }
}
''');
        for (String object in Namer.userGlobalObjects) {
        mainBuffer.add('''
if (typeof $printHelperName === "function") {
  $printHelperName("Size of $object: "
                   + String(Object.getOwnPropertyNames($object).length)
                   + ", fast properties " + %HasFastProperties($object));
}
''');
        }
      }

      emitMain(mainBuffer);
      jsAst.FunctionDeclaration precompiledFunctionAst =
          buildPrecompiledFunction();
      emitInitFunction(mainBuffer);
      if (!areAnyElementsDeferred) {
        mainBuffer.add('})()\n');
      } else {
        mainBuffer.add('\n');
      }
      compiler.assembledCode = mainBuffer.getText();
      outputSourceMap(compiler.assembledCode, '');

      mainBuffer.write(
          jsAst.prettyPrint(
              precompiledFunctionAst, compiler,
              allowVariableMinification: false).getText());

      compiler.outputProvider('', 'precompiled.js')
          ..add(mainBuffer.getText())
          ..close();

      emitDeferredCode();

    });
    return compiler.assembledCode;
  }

  CodeBuffer bufferForElement(Element element, CodeBuffer eagerBuffer) {
    Element owner = element.getLibrary();
    if (!element.isTopLevel() && !element.isNative()) {
      // For static (not top level) elements, record their code in a buffer
      // specific to the class. For now, not supported for native classes and
      // native elements.
      ClassElement cls =
          element.getEnclosingClassOrCompilationUnit().declaration;
      if (compiler.codegenWorld.instantiatedClasses.contains(cls)
          && !cls.isNative()) {
        owner = cls;
      }
    }
    if (owner == null) {
      compiler.internalErrorOnElement(element, 'Owner is null');
    }
    List<CodeBuffer> buffers = elementBuffers.putIfAbsent(
        owner, () => <CodeBuffer>[null, null]);
    bool deferred = isDeferred(element);
    int index = deferred ? 1 : 0;
    CodeBuffer buffer = buffers[index];
    if (buffer == null) {
      buffer = buffers[index] = new CodeBuffer();
    }
    return buffer;
  }

  /**
   * Returns the appropriate buffer for [constant].  If [constant] is
   * itself an instance of a deferred type (or built from constants
   * that are instances of deferred types) attempting to use
   * [constant] before the deferred type has been loaded will not
   * work, and [constant] itself must be deferred.
   */
  CodeBuffer bufferForConstant(Constant constant, CodeBuffer eagerBuffer) {
    var queue = new Queue()..add(constant);
    while (!queue.isEmpty) {
      constant = queue.removeFirst();
      if (isDeferred(constant.computeType(compiler).element)) {
        return deferredConstants;
      }
      queue.addAll(constant.getDependencies());
    }
    return eagerBuffer;
  }



  void emitDeferredCode() {
    if (deferredLibraries.isEmpty && deferredConstants.isEmpty) return;

    var oldClassesCollector = classesCollector;
    classesCollector = r"$$";

    // It does not make sense to defer constants if there are no
    // deferred elements.
    assert(!deferredLibraries.isEmpty);

    var buffer = new CodeBuffer()
        ..write(buildGeneratedBy())
        ..write('var old${namer.CURRENT_ISOLATE}$_='
                '$_${namer.CURRENT_ISOLATE}$N'
                // TODO(ahe): This defines a lot of properties on the
                // Isolate.prototype object.  We know this will turn it into a
                // slow object in V8, so instead we should do something similar
                // to Isolate.$finishIsolateConstructor.
                '${namer.CURRENT_ISOLATE}$_='
                '$_${namer.isolateName}.prototype$N$n'
                // The classesCollector object ($$).
                '$classesCollector$_=$_{};$n')
        ..write(getReflectionDataParser(classesCollector, namer))
        ..write('([$n')
        ..addBuffer(deferredLibraries)
        ..write('])$N');

    if (!deferredClasses.isEmpty) {
      buffer.write(
          '$finishClassesName($classesCollector,$_${namer.CURRENT_ISOLATE},'
          '$_$isolatePropertiesName)$N');
    }

    buffer.write(
        // Reset the classesCollector ($$).
        '$classesCollector$_=${_}null$N$n'
        '${namer.CURRENT_ISOLATE}$_=${_}old${namer.CURRENT_ISOLATE}$N');

    classesCollector = oldClassesCollector;

    if (!deferredConstants.isEmpty) {
      buffer.addBuffer(deferredConstants);
    }

    String code = buffer.getText();
    compiler.outputProvider('part', 'js')
      ..add(code)
      ..close();
    outputSourceMap(compiler.assembledCode, 'part');
  }

  String buildGeneratedBy() {
    var suffix = '';
    if (compiler.hasBuildId) suffix = ' version: ${compiler.buildId}';
    return '// Generated by dart2js, the Dart to JavaScript compiler$suffix.\n';
  }

  String buildSourceMap(CodeBuffer buffer, SourceFile compiledFile) {
    SourceMapBuilder sourceMapBuilder =
        new SourceMapBuilder(compiler.sourceMapUri);
    buffer.forEachSourceLocation(sourceMapBuilder.addMapping);
    return sourceMapBuilder.build(compiledFile);
  }

  void outputSourceMap(String code, String name) {
    if (!generateSourceMap) return;
    SourceFile compiledFile = new SourceFile(null, compiler.assembledCode);
    String sourceMap = buildSourceMap(mainBuffer, compiledFile);
    compiler.outputProvider(name, 'js.map')
        ..add(sourceMap)
        ..close();
  }

  bool isDeferred(Element element) {
    return compiler.deferredLoadTask.isDeferred(element);
  }

  bool get areAnyElementsDeferred {
    return compiler.deferredLoadTask.areAnyElementsDeferred;
  }
}
