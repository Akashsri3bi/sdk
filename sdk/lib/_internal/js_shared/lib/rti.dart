// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// This library contains support for runtime type information.
library rti;

import 'dart:_foreign_helper'
    show
        getInterceptor,
        getJSArrayInteropRti,
        JS,
        JS_BUILTIN,
        JS_EMBEDDED_GLOBAL,
        JS_GET_FLAG,
        JS_GET_NAME,
        JS_STRING_CONCAT,
        RAW_DART_FUNCTION_REF,
        TYPE_REF,
        LEGACY_TYPE_REF;
import 'dart:_interceptors'
    show JavaScriptFunction, JSArray, JSNull, JSUnmodifiableArray;
import 'dart:_js_names' show unmangleGlobalNameIfPreservedAnyways;
import 'dart:_js_shared_embedded_names';
import 'dart:_recipe_syntax';

/// The name of a property on the constructor function of Dart Object
/// and interceptor types, used for caching Rti types.
const CONSTRUCTOR_RTI_CACHE_PROPERTY_NAME = r'$ccache';

// The top type `Object?` is used throughout this library even when values are
// not nullable or have narrower types in order to avoid incurring type checks
// before the type checking infrastructure has been set up.
// We could use `dynamic`, but this would allow inadvertent implicit downcasts.
// TODO(fishythefish, dart-lang/language#115): Replace `Object?` with a typedef
// when possible.

/// An Rti object represents both a type (e.g `Map<int, String>`) and a type
/// environment (`Map<int, String>` binds `Map.K=int` and `Map.V=String`).
///
/// There is a single [Rti] class to help reduce polymorphism in the JavaScript
/// runtime. The class has a default constructor and no final fields so it can
/// be created before much of the runtime exists.
///
/// The fields are declared in an order that gets shorter minified names for the
/// more commonly used fields. (TODO: we should exploit the fact that an Rti
/// instance never appears in a dynamic context, so does not need field names to
/// be distinct from dynamic selectors).
///
class Rti {
  /// JavaScript method for 'as' check. The method is called from generated code,
  /// e.g. `o as T` generates something like `rtiForT._as(o)`.
  @pragma('dart2js:noElision')
  Object? _as;

  /// JavaScript method for 'is' test.  The method is called from generated
  /// code, e.g. `o is T` generates something like `rtiForT._is(o)`.
  @pragma('dart2js:noElision')
  Object? _is;

  static void _setAsCheckFunction(Rti rti, Object? fn) {
    rti._as = fn;
  }

  static void _setIsTestFunction(Rti rti, Object? fn) {
    rti._is = fn;
  }

  @pragma('dart2js:tryInline')
  static Object? _asCheck(Rti rti, Object? object) {
    return JS('', '#.#(#)', rti, JS_GET_NAME(JsGetName.RTI_FIELD_AS), object);
  }

  @pragma('dart2js:tryInline')
  static bool _isCheck(Rti rti, Object? object) {
    return JS(
        'bool', '#.#(#)', rti, JS_GET_NAME(JsGetName.RTI_FIELD_IS), object);
  }

  /// Method called from generated code to evaluate a type environment recipe in
  /// `this` type environment.
  Rti _eval(Object? recipe) {
    // TODO(sra): Clone the fast-path of _Universe.evalInEnvironment to here.
    return _rtiEval(this, _Utils.asString(recipe));
  }

  /// Method called from generated code to extend `this` type environment (an
  /// interface or binding Rti) with function type arguments (a singleton
  /// argument or tuple of arguments).
  Rti _bind(Object? typeOrTuple) => _rtiBind(this, _Utils.asRti(typeOrTuple));

  /// Method called from generated code to extend `this` type (as a singleton
  /// type environment) with function type arguments (a singleton argument or
  /// tuple of arguments).
  Rti _bind1(Object? typeOrTuple) => _rtiBind1(this, _Utils.asRti(typeOrTuple));

  // Precomputed derived types. These fields are used to hold derived types that
  // are computed eagerly.
  // TODO(sra): Implement precomputed type optimizations.

  /// If kind == kindInterface, holds the first type argument (if any).
  /// If kind == kindFutureOr, holds Future<T> where T is the base type.
  /// - This case is lazily initialized during subtype checks.
  /// If kind == kindStar, holds T? where T is the base type.
  /// - This case is lazily initialized during subtype checks.
  @pragma('dart2js:noElision')
  Object? _precomputed1;

  static Object? _getPrecomputed1(Rti rti) => rti._precomputed1;

  static void _setPrecomputed1(Rti rti, Object? precomputed) {
    rti._precomputed1 = precomputed;
  }

  static Rti _getQuestionFromStar(Object? universe, Rti rti) {
    assert(_getKind(rti) == kindStar);
    Rti? question = _Utils.asRtiOrNull(_getPrecomputed1(rti));
    if (question == null) {
      question =
          _Universe._lookupQuestionRti(universe, _getStarArgument(rti), true);
      Rti._setPrecomputed1(rti, question);
    }
    return question;
  }

  static Rti _getFutureFromFutureOr(Object? universe, Rti rti) {
    assert(_getKind(rti) == kindFutureOr);
    Rti? future = _Utils.asRtiOrNull(_getPrecomputed1(rti));
    if (future == null) {
      future = _Universe._lookupFutureRti(universe, _getFutureOrArgument(rti));
      Rti._setPrecomputed1(rti, future);
    }
    return future;
  }

  Object? _precomputed2;
  Object? _precomputed3;
  Object? _precomputed4;

  // Data value used by some tests.
  @pragma('dart2js:noElision')
  Object? _specializedTestResource;

  static Object? _getSpecializedTestResource(Rti rti) {
    return rti._specializedTestResource;
  }

  static void _setSpecializedTestResource(Rti rti, Object? value) {
    rti._specializedTestResource = value;
  }

  // The Type object corresponding to this Rti.
  Object? _cachedRuntimeType;
  static _Type? _getCachedRuntimeType(Rti rti) =>
      JS('_Type|Null', '#', rti._cachedRuntimeType);
  static void _setCachedRuntimeType(Rti rti, _Type type) {
    rti._cachedRuntimeType = type;
  }

  /// The kind of Rti `this` is, one of the kindXXX constants below.
  ///
  /// We don't use an enum since we need to create Rti objects very early.
  ///
  /// The zero initializer ensures dart2js type analysis considers [_kind] is
  /// non-nullable.
  Object? /*int*/ _kind = 0;

  static int _getKind(Rti rti) => _Utils.asInt(rti._kind);
  static void _setKind(Rti rti, int kind) {
    rti._kind = kind;
  }

  // Terminal terms.
  static const int kindNever = 1;
  static const int kindDynamic = 2;
  static const int kindVoid = 3; // TODO(sra): Use `dynamic` instead?
  static const int kindAny = 4; // Dart1-style 'dynamic' for JS-interop.
  static const int kindErased = 5;
  // Unary terms.
  static const int kindStar = 6;
  static const int kindQuestion = 7;
  static const int kindFutureOr = 8;
  // More complex terms.
  static const int kindInterface = 9;
  // A vector of type parameters from enclosing functions and closures.
  static const int kindBinding = 10;
  static const int kindFunction = 11;
  static const int kindGenericFunction = 12;
  static const int kindGenericFunctionParameter = 13;

  static bool _isUnionOfFunctionType(Rti rti) {
    int kind = Rti._getKind(rti);
    if (kind == kindStar || kind == kindQuestion || kind == kindFutureOr) {
      return _isUnionOfFunctionType(_Utils.asRti(_getPrimary(rti)));
    }
    return kind == kindFunction || kind == kindGenericFunction;
  }

  /// Primary data associated with type.
  ///
  /// - Minified name of interface for interface types.
  /// - Underlying type for unary terms.
  /// - Class part of a type environment inside a generic class, or `null` for
  ///   type tuple.
  /// - Return type of a function type.
  /// - Underlying function type for a generic function.
  /// - de Bruijn index for a generic function parameter.
  Object? _primary;

  static Object? _getPrimary(Rti rti) => rti._primary;
  static void _setPrimary(Rti rti, Object? value) {
    rti._primary = value;
  }

  /// Additional data associated with type.
  ///
  /// - The type arguments of an interface type.
  /// - The type arguments from enclosing functions and closures for a
  ///   kindBinding.
  /// - The [_FunctionParameters] of a function type.
  /// - The type parameter bounds of a generic function.
  Object? _rest;

  static Object? _getRest(Rti rti) => rti._rest;
  static void _setRest(Rti rti, Object? value) {
    rti._rest = value;
  }

  static String _getInterfaceName(Rti rti) {
    assert(_getKind(rti) == kindInterface);
    return _Utils.asString(_getPrimary(rti));
  }

  static JSArray _getInterfaceTypeArguments(Rti rti) {
    // The array is a plain JavaScript Array, otherwise we would need the type
    // `JSArray<Rti>` to exist before we could create the type `JSArray<Rti>`.
    assert(_getKind(rti) == kindInterface);
    return JS('JSUnmodifiableArray', '#', _getRest(rti));
  }

  static Rti _getBindingBase(Rti rti) {
    assert(_getKind(rti) == kindBinding);
    return _Utils.asRti(_getPrimary(rti));
  }

  static JSArray _getBindingArguments(Rti rti) {
    assert(_getKind(rti) == kindBinding);
    return JS('JSUnmodifiableArray', '#', _getRest(rti));
  }

  static Rti _getStarArgument(Rti rti) {
    assert(_getKind(rti) == kindStar);
    return _Utils.asRti(_getPrimary(rti));
  }

  static Rti _getQuestionArgument(Rti rti) {
    assert(_getKind(rti) == kindQuestion);
    return _Utils.asRti(_getPrimary(rti));
  }

  static Rti _getFutureOrArgument(Rti rti) {
    assert(_getKind(rti) == kindFutureOr);
    return _Utils.asRti(_getPrimary(rti));
  }

  static Rti _getReturnType(Rti rti) {
    assert(_getKind(rti) == kindFunction);
    return _Utils.asRti(_getPrimary(rti));
  }

  static _FunctionParameters _getFunctionParameters(Rti rti) {
    assert(_getKind(rti) == kindFunction);
    return JS('_FunctionParameters', '#', _getRest(rti));
  }

  static Rti _getGenericFunctionBase(Rti rti) {
    assert(_getKind(rti) == kindGenericFunction);
    return _Utils.asRti(_getPrimary(rti));
  }

  static JSArray _getGenericFunctionBounds(Rti rti) {
    assert(_getKind(rti) == kindGenericFunction);
    return JS('JSUnmodifiableArray', '#', _getRest(rti));
  }

  static int _getGenericFunctionParameterIndex(Rti rti) {
    assert(_getKind(rti) == kindGenericFunctionParameter);
    return _Utils.asInt(_getPrimary(rti));
  }

  /// On [Rti]s that are type environments*, derived types are cached on the
  /// environment to ensure fast canonicalization. Ground-term types (i.e. not
  /// dependent on class or function type parameters) are cached in the
  /// universe. This field starts as `null` and the cache is created on demand.
  ///
  /// *Any Rti can be a type environment, since we use the type for a function
  /// type environment. The ambiguity between 'generic class is the environment'
  /// and 'generic class is a singleton type argument' is resolved by using
  /// different indexing in the recipe.
  Object? _evalCache;

  static Object? _getEvalCache(Rti rti) => rti._evalCache;
  static void _setEvalCache(Rti rti, Object? value) {
    rti._evalCache = value;
  }

  /// On [Rti]s that are type environments*, extended environments are cached on
  /// the base environment to ensure fast canonicalization.
  ///
  /// This field starts as `null` and the cache is created on demand.
  ///
  /// *This is valid only on kindInterface and kindBinding Rtis. The ambiguity
  /// between 'generic class is the base environment' and 'generic class is a
  /// singleton type argument' is resolved [TBD] (either (1) a bind1 cache, or
  /// (2)using `env._eval("@<0>")._bind(args)` in place of `env._bind1(args)`).
  ///
  /// On [Rti]s that are generic function types, results of instantiation are
  /// cached on the generic function type to ensure fast repeated
  /// instantiations.
  Object? _bindCache;

  static Object? _getBindCache(Rti rti) => rti._bindCache;
  static void _setBindCache(Rti rti, Object? value) {
    rti._bindCache = value;
  }

  static Rti allocate() {
    return Rti();
  }

  Object? _canonicalRecipe;

  static String _getCanonicalRecipe(Rti rti) {
    var s = rti._canonicalRecipe;
    assert(_Utils.isString(s), 'Missing canonical recipe');
    return _Utils.asString(s);
  }

  static void _setCanonicalRecipe(Rti rti, String s) {
    rti._canonicalRecipe = s;
  }
}

class _FunctionParameters {
  static _FunctionParameters allocate() => _FunctionParameters();

  Object? _requiredPositional;
  static JSArray _getRequiredPositional(_FunctionParameters parameters) =>
      JS('JSUnmodifiableArray', '#', parameters._requiredPositional);
  static void _setRequiredPositional(
      _FunctionParameters parameters, Object? requiredPositional) {
    parameters._requiredPositional = requiredPositional;
  }

  Object? _optionalPositional;
  static JSArray _getOptionalPositional(_FunctionParameters parameters) =>
      JS('JSUnmodifiableArray', '#', parameters._optionalPositional);
  static void _setOptionalPositional(
      _FunctionParameters parameters, Object? optionalPositional) {
    parameters._optionalPositional = optionalPositional;
  }

  /// These are a sequence of name/bool/type triplets that correspond to named
  /// parameters.
  ///
  ///   void foo({int bar, required double baz})
  ///
  /// would be encoded as ["bar", false, int, "baz", true, double], where each
  /// triplet consists of the name [String], a bool indicating whether or not
  /// the parameter is required, and the [Rti].
  ///
  /// Invariant: These groups are sorted by name in lexicographically ascending order.
  Object? _named;
  static JSArray _getNamed(_FunctionParameters parameters) =>
      JS('JSUnmodifiableArray', '#', parameters._named);
  static void _setNamed(_FunctionParameters parameters, Object? named) {
    parameters._named = named;
  }
}

Object? _theUniverse() => JS_EMBEDDED_GLOBAL('', RTI_UNIVERSE);

Rti _rtiEval(Rti environment, String recipe) {
  return _Universe.evalInEnvironment(_theUniverse(), environment, recipe);
}

Rti _rtiBind1(Rti environment, Rti types) {
  return _Universe.bind1(_theUniverse(), environment, types);
}

Rti _rtiBind(Rti environment, Rti types) {
  return _Universe.bind(_theUniverse(), environment, types);
}

/// Evaluate a ground-term type.
/// Called from generated code.
Rti findType(String recipe) {
  // Since [findType] should only be called on recipes computed during
  // compilation, we can assume that the recipe is already normalized (since all
  // [DartType]s are normalized. This allows us to avoid an unfortunate cycle:
  //
  // If we attempt to normalize here, then during the course of normalization,
  // we may attempt to access a [TYPE_REF]. This uses the `type$` object, and
  // the values of this object are calls to [findType]. Thus, if we're currently
  // in one of these calls, then `type$` will appear to be undefined.
  return _Universe.eval(_theUniverse(), recipe, false);
}

/// Evaluate a type recipe in the environment of an instance.
Rti evalInInstance(Object? instance, String recipe) {
  return _rtiEval(instanceType(instance), recipe);
}

/// Returns [genericFunctionRti] with type parameters bound to those specified
/// by [instantiationRti].
///
/// [genericFunctionRti] must be an rti representation with a number of generic
/// type parameters matching the number of types provided by [instantiationRti].
///
/// Called from generated code.
@pragma('dart2js:noInline')
Rti? instantiatedGenericFunctionType(
    Rti? genericFunctionRti, Rti instantiationRti) {
  // If --lax-runtime-type-to-string is enabled and we never check the function
  // type, then the function won't have a signature, so its RTI will be null. In
  // this case, there is nothing to instantiate, so we return `null` and the
  // instantiation appears to be an interface type instead.
  if (genericFunctionRti == null) return null;
  var bounds = Rti._getGenericFunctionBounds(genericFunctionRti);
  var typeArguments = Rti._getInterfaceTypeArguments(instantiationRti);
  assert(_Utils.arrayLength(bounds) == _Utils.arrayLength(typeArguments));

  var cache = Rti._getBindCache(genericFunctionRti);
  if (cache == null) {
    cache = JS('', 'new Map()');
    Rti._setBindCache(genericFunctionRti, cache);
  }
  String key = Rti._getCanonicalRecipe(instantiationRti);
  var probe = _Utils.mapGet(cache, key);
  if (probe != null) return _Utils.asRti(probe);
  Rti rti = _substitute(_theUniverse(),
      Rti._getGenericFunctionBase(genericFunctionRti), typeArguments, 0);
  _Utils.mapSet(cache, key, rti);
  return rti;
}

/// Substitutes [typeArguments] for generic function parameters in [rti].
///
/// Generic function parameters are de Bruijn indices counting up through the
/// parameters' scopes to index into [typeArguments].
///
/// [depth] is the number of subsequent generic function parameters that are in
/// scope. This is subtracted off the de Bruijn index for the type parameter to
/// arrive at an potential index into [typeArguments].
///
/// In order to do a partial substitution - that is, substituting only some
/// type parameters rather than all of them - we encode the unsubstituted
/// positions of the argument list as `undefined` or `null`.
Rti _substitute(Object? universe, Rti rti, Object? typeArguments, int depth) {
  int kind = Rti._getKind(rti);
  switch (kind) {
    case Rti.kindErased:
    case Rti.kindNever:
    case Rti.kindDynamic:
    case Rti.kindVoid:
    case Rti.kindAny:
      return rti;
    case Rti.kindStar:
      Rti baseType = _Utils.asRti(Rti._getPrimary(rti));
      Rti substitutedBaseType =
          _substitute(universe, baseType, typeArguments, depth);
      if (_Utils.isIdentical(substitutedBaseType, baseType)) return rti;
      return _Universe._lookupStarRti(universe, substitutedBaseType, true);
    case Rti.kindQuestion:
      Rti baseType = _Utils.asRti(Rti._getPrimary(rti));
      Rti substitutedBaseType =
          _substitute(universe, baseType, typeArguments, depth);
      if (_Utils.isIdentical(substitutedBaseType, baseType)) return rti;
      return _Universe._lookupQuestionRti(universe, substitutedBaseType, true);
    case Rti.kindFutureOr:
      Rti baseType = _Utils.asRti(Rti._getPrimary(rti));
      Rti substitutedBaseType =
          _substitute(universe, baseType, typeArguments, depth);
      if (_Utils.isIdentical(substitutedBaseType, baseType)) return rti;
      return _Universe._lookupFutureOrRti(universe, substitutedBaseType, true);
    case Rti.kindInterface:
      var interfaceTypeArguments = Rti._getInterfaceTypeArguments(rti);
      var substitutedInterfaceTypeArguments = _substituteArray(
          universe, interfaceTypeArguments, typeArguments, depth);
      if (_Utils.isIdentical(
          substitutedInterfaceTypeArguments, interfaceTypeArguments))
        return rti;
      return _Universe._lookupInterfaceRti(universe, Rti._getInterfaceName(rti),
          substitutedInterfaceTypeArguments);
    case Rti.kindBinding:
      Rti base = Rti._getBindingBase(rti);
      Rti substitutedBase = _substitute(universe, base, typeArguments, depth);
      var arguments = Rti._getBindingArguments(rti);
      var substitutedArguments =
          _substituteArray(universe, arguments, typeArguments, depth);
      if (_Utils.isIdentical(substitutedBase, base) &&
          _Utils.isIdentical(substitutedArguments, arguments)) return rti;
      return _Universe._lookupBindingRti(
          universe, substitutedBase, substitutedArguments);
    case Rti.kindFunction:
      Rti returnType = Rti._getReturnType(rti);
      Rti substitutedReturnType =
          _substitute(universe, returnType, typeArguments, depth);
      _FunctionParameters functionParameters = Rti._getFunctionParameters(rti);
      _FunctionParameters substitutedFunctionParameters =
          _substituteFunctionParameters(
              universe, functionParameters, typeArguments, depth);
      if (_Utils.isIdentical(substitutedReturnType, returnType) &&
          _Utils.isIdentical(substitutedFunctionParameters, functionParameters))
        return rti;
      return _Universe._lookupFunctionRti(
          universe, substitutedReturnType, substitutedFunctionParameters);
    case Rti.kindGenericFunction:
      var bounds = Rti._getGenericFunctionBounds(rti);
      depth += _Utils.arrayLength(bounds);
      var substitutedBounds =
          _substituteArray(universe, bounds, typeArguments, depth);
      Rti base = Rti._getGenericFunctionBase(rti);
      Rti substitutedBase = _substitute(universe, base, typeArguments, depth);
      if (_Utils.isIdentical(substitutedBounds, bounds) &&
          _Utils.isIdentical(substitutedBase, base)) return rti;
      return _Universe._lookupGenericFunctionRti(
          universe, substitutedBase, substitutedBounds, true);
    case Rti.kindGenericFunctionParameter:
      int index = Rti._getGenericFunctionParameterIndex(rti);
      // Indices below the current depth are out of scope for substitution and
      // can be returned unchanged.
      if (index < depth) return rti;
      var argument = _Utils.arrayAt(typeArguments, index - depth);
      // In order to do a partial substitution - that is, substituting only some
      // type parameters rather than all of them - we encode the unsubstituted
      // positions of the argument list as `undefined` (which will compare equal
      // to `null`).
      if (argument == null) return rti;
      return _Utils.asRti(argument);
    default:
      throw AssertionError('Attempted to substitute unexpected RTI kind $kind');
  }
}

Object? _substituteArray(
    Object? universe, Object? rtiArray, Object? typeArguments, int depth) {
  bool changed = false;
  int length = _Utils.arrayLength(rtiArray);
  Object? result = _Utils.newArrayOrEmpty(length);
  for (int i = 0; i < length; i++) {
    Rti rti = _Utils.asRti(_Utils.arrayAt(rtiArray, i));
    Rti substitutedRti = _substitute(universe, rti, typeArguments, depth);
    if (_Utils.isNotIdentical(substitutedRti, rti)) {
      changed = true;
    }
    _Utils.arraySetAt(result, i, substitutedRti);
  }
  return changed ? result : rtiArray;
}

Object? _substituteNamed(
    Object? universe, Object? namedArray, Object? typeArguments, int depth) {
  bool changed = false;
  int length = _Utils.arrayLength(namedArray);
  assert(_Utils.isMultipleOf(length, 3));
  Object? result = _Utils.newArrayOrEmpty(length);
  for (int i = 0; i < length; i += 3) {
    String name = _Utils.asString(_Utils.arrayAt(namedArray, i));
    bool isRequired = _Utils.asBool(_Utils.arrayAt(namedArray, i + 1));
    Rti rti = _Utils.asRti(_Utils.arrayAt(namedArray, i + 2));
    Rti substitutedRti = _substitute(universe, rti, typeArguments, depth);
    if (_Utils.isNotIdentical(substitutedRti, rti)) {
      changed = true;
    }
    JS('', '#.splice(#, #, #, #, #)', result, i, 3, name, isRequired,
        substitutedRti);
  }
  return changed ? result : namedArray;
}

_FunctionParameters _substituteFunctionParameters(Object? universe,
    _FunctionParameters functionParameters, Object? typeArguments, int depth) {
  var requiredPositional =
      _FunctionParameters._getRequiredPositional(functionParameters);
  var substitutedRequiredPositional =
      _substituteArray(universe, requiredPositional, typeArguments, depth);
  var optionalPositional =
      _FunctionParameters._getOptionalPositional(functionParameters);
  var substitutedOptionalPositional =
      _substituteArray(universe, optionalPositional, typeArguments, depth);
  var named = _FunctionParameters._getNamed(functionParameters);
  var substitutedNamed =
      _substituteNamed(universe, named, typeArguments, depth);
  if (_Utils.isIdentical(substitutedRequiredPositional, requiredPositional) &&
      _Utils.isIdentical(substitutedOptionalPositional, optionalPositional) &&
      _Utils.isIdentical(substitutedNamed, named)) return functionParameters;
  _FunctionParameters result = _FunctionParameters.allocate();
  _FunctionParameters._setRequiredPositional(
      result, substitutedRequiredPositional);
  _FunctionParameters._setOptionalPositional(
      result, substitutedOptionalPositional);
  _FunctionParameters._setNamed(result, substitutedNamed);
  return result;
}

bool _isDartObject(Object? object) => _Utils.instanceOf(object,
    JS_BUILTIN('depends:none;effects:none;', JsBuiltin.dartObjectConstructor));

bool _isClosure(Object? object) => _Utils.instanceOf(object,
    JS_BUILTIN('depends:none;effects:none;', JsBuiltin.dartClosureConstructor));

/// Stores an Rti on a JavaScript Array (JSArray).
/// Rti is recovered by [_arrayInstanceType].
/// Called from generated code.
// Don't inline.  Let the JS engine inline this.  The call expression is much
// more compact that the inlined expansion.
@pragma('dart2js:noInline')
Object? _setArrayType(Object? target, Object? rti) {
  assert(rti != null);
  var rtiProperty = JS_EMBEDDED_GLOBAL('', ARRAY_RTI_PROPERTY);
  JS('var', r'#[#] = #', target, rtiProperty, rti);
  return target;
}

/// Returns the structural function [Rti] of [closure], or `null`.
/// [closure] must be a subclass of [Closure].
/// Called from generated code.
Rti? closureFunctionType(Object? closure) {
  var signatureName = JS_GET_NAME(JsGetName.SIGNATURE_NAME);
  var signature = JS('', '#[#]', closure, signatureName);
  if (signature != null) {
    if (JS('bool', 'typeof # == "number"', signature)) {
      return getTypeFromTypesTable(_Utils.asInt(signature));
    }
    return _Utils.asRti(JS('', '#[#]()', closure, signatureName));
  }
  return null;
}

/// Returns the Rti type of [object]. Closures have both an interface type
/// (Closures implement `Function`) and a structural function type. Uses
/// [testRti] to choose the appropriate type.
///
/// Called from generated code.
Rti instanceOrFunctionType(Object? object, Rti testRti) {
  if (Rti._isUnionOfFunctionType(testRti)) {
    if (_isClosure(object)) {
      // If [testRti] is e.g. `FutureOr<Action>` (where `Action` is some
      // function type), we don't need to worry about the `Future<Action>`
      // branch because closures can't be `Future`s.
      Rti? rti = closureFunctionType(object);
      if (rti != null) return rti;
    }
  }
  return instanceType(object);
}

/// Returns the Rti type of [object].
/// This is the general entry for obtaining the interface type of any value.
/// Called from generated code.
Rti instanceType(Object? object) {
  // TODO(sra): Add interceptor-based specializations of this method. Inject a
  // _getRti method into (Dart)Object, JSArray, and Interceptor. Then calls to
  // this method can be generated as `getInterceptor(o)._getRti(o)`, allowing
  // interceptor optimizations to select the specialization. If the only use of
  // `getInterceptor` is for calling `_getRti`, then `instanceType` can be
  // called, similar to a one-shot interceptor call. This would improve type
  // lookup in ListMixin code as the interceptor is JavaScript 'this'.

  if (_isDartObject(object)) {
    return _instanceType(object);
  }

  if (_Utils.isArray(object)) {
    return _arrayInstanceType(object);
  }

  var interceptor = getInterceptor(object);
  return _instanceTypeFromConstructor(interceptor);
}

/// Returns the Rti type of JavaScript Array [object].
/// Called from generated code.
Rti _arrayInstanceType(Object? object) {
  // A JavaScript Array can come from three places:
  //   1. This Dart program.
  //   2. Another Dart program loaded in the JavaScript environment.
  //   3. From outside of a Dart program.
  //
  // In case 3 we default to a fixed type for all external Arrays.  To protect
  // against an Array passed between two Dart programs loaded into the same
  // JavaScript isolate (communicating e.g. via JS-interop), we check that the
  // stored value is 'our' Rti type.
  //
  // TODO(40175): Investigate if it is more efficient to have each Dart program
  // use a unique JavaScript property so that both case 2 and case 3 look like a
  // missing value. In ES6 we could use a globally named JavaScript Symbol. For
  // IE11 we would have to synthesise a String property-name with almost zero
  // chance of conflict.

  var rti = JS('', r'#[#]', object, JS_EMBEDDED_GLOBAL('', ARRAY_RTI_PROPERTY));
  var defaultRti = getJSArrayInteropRti();

  // Case 3.
  if (rti == null) return _Utils.asRti(defaultRti);

  // Case 2 and perhaps case 3. Check constructor of extracted type against a
  // known instance of Rti - this is an easy way to get the constructor.
  if (JS('bool', '#.constructor !== #.constructor', rti, defaultRti)) {
    return _Utils.asRti(defaultRti);
  }

  // Case 1.
  return _Utils.asRti(rti);
}

/// Returns the Rti type of user-defined class [object].
/// [object] must not be an intercepted class or a closure.
/// Called from generated code.
Rti _instanceType(Object? object) {
  var rti = JS('', r'#[#]', object, JS_GET_NAME(JsGetName.RTI_NAME));
  return rti != null ? _Utils.asRti(rti) : _instanceTypeFromConstructor(object);
}

String instanceTypeName(Object? object) {
  Rti rti = instanceType(object);
  return _rtiToString(rti, null);
}

Rti _instanceTypeFromConstructor(Object? instance) {
  var constructor = JS('', '#.constructor', instance);
  var probe = JS('', r'#[#]', constructor, CONSTRUCTOR_RTI_CACHE_PROPERTY_NAME);
  if (probe != null) return _Utils.asRti(probe);
  return _instanceTypeFromConstructorMiss(instance, constructor);
}

@pragma('dart2js:noInline')
Rti _instanceTypeFromConstructorMiss(Object? instance, Object? constructor) {
  // Subclasses of Closure are synthetic classes. The synthetic classes all
  // extend a 'normal' class (Closure, BoundClosure, StaticClosure), so make
  // them appear to be the superclass. Instantiations have a `$ti` field so
  // don't reach here.
  //
  // TODO(39214): This will need fixing if we ever use instances of
  // StaticClosure for static tear-offs.
  //
  // TODO(sra): Can this test be avoided, e.g. by putting $ti on the
  // prototype of Closure/BoundClosure/StaticClosure classes?
  var effectiveConstructor = _isClosure(instance)
      ? JS('', '#.__proto__.__proto__.constructor', instance)
      : constructor;
  Rti rti = _Universe.findErasedType(
      _theUniverse(), JS('String', '#.name', effectiveConstructor));
  JS('', r'#[#] = #', constructor, CONSTRUCTOR_RTI_CACHE_PROPERTY_NAME, rti);
  return rti;
}

/// Returns the structural function type of [object], or `null` if the object is
/// not a closure.
Rti? _instanceFunctionType(Object? object) =>
    _isClosure(object) ? closureFunctionType(object) : null;

/// Returns Rti from types table. The types table is initialized with recipe
/// strings.
Rti getTypeFromTypesTable(int index) {
  var table = JS_EMBEDDED_GLOBAL('', TYPES);
  var type = _Utils.arrayAt(table, index);
  if (_Utils.isString(type)) {
    Rti rti = findType(_Utils.asString(type));
    _Utils.arraySetAt(table, index, rti);
    return rti;
  }
  return _Utils.asRti(type);
}

Type getRuntimeType(Object? object) {
  Rti rti = _instanceFunctionType(object) ?? instanceType(object);
  return createRuntimeType(rti);
}

/// Called from generated code.
Type createRuntimeType(Rti rti) {
  _Type? type = Rti._getCachedRuntimeType(rti);
  if (type != null) return type;
  if (JS_GET_FLAG('PRINT_LEGACY_STARS')) {
    return _Type(rti);
  } else {
    String recipe = Rti._getCanonicalRecipe(rti);
    String starErasedRecipe = JS('String', '#.replace(/\\*/g, "")', recipe);
    if (starErasedRecipe == recipe) {
      return _Type(rti);
    }
    Rti starErasedRti = _Universe.eval(_theUniverse(), starErasedRecipe, true);
    type = Rti._getCachedRuntimeType(starErasedRti) ?? _Type(starErasedRti);
    Rti._setCachedRuntimeType(rti, type);
    return type;
  }
}

/// Called from generated code in the constant pool.
Type typeLiteral(String recipe) {
  return createRuntimeType(findType(recipe));
}

/// Implementation of [Type] based on Rti.
class _Type implements Type {
  final Rti _rti;

  _Type(this._rti) : assert(Rti._getCachedRuntimeType(_rti) == null) {
    Rti._setCachedRuntimeType(_rti, this);
  }

  @override
  String toString() => _rtiToString(_rti, null);
}

/// Called from generated code.
///
/// The first time the default `_is` method is called, it replaces itself with a
/// specialized version.
// TODO(sra): Emit code to force-replace the `_is` method, generated dependent
// on the types used in the program. e.g.
//
//     findType("bool")._is = H._isBool;
//
// This could be omitted if (1) the `bool` rti is not used directly for a test
// (e.g. we lower a check to a direct helper), and (2) `bool` does not flow to a
// tested type parameter. The trick will be to ensure that `H._isBool` is
// generated.
bool _installSpecializedIsTest(Object? object) {
  // This static method is installed on an Rti object as a JavaScript instance
  // method. The Rti object is 'this'.
  Rti testRti = _Utils.asRti(JS('', 'this'));

  if (isObjectType(testRti)) {
    return _finishIsFn(testRti, object, RAW_DART_FUNCTION_REF(_isObject));
  }
  if (isTopType(testRti)) {
    return _finishIsFn(testRti, object, RAW_DART_FUNCTION_REF(_isTop));
  }

  // `o is T*` generally behaves like `o is T`.
  // The exceptions are `Object*` (handled above) and `Never*`
  //
  //   `null is Never`  --> `false`
  //   `null is Never*` --> `true`
  Rti unstarred = Rti._getKind(testRti) == Rti.kindStar
      ? Rti._getStarArgument(testRti)
      : testRti;

  var isFn = _simpleSpecializedIsTest(unstarred);
  if (isFn != null) {
    return _finishIsFn(testRti, object, isFn);
  }

  if (Rti._getKind(unstarred) == Rti.kindInterface) {
    String name = Rti._getInterfaceName(unstarred);
    var arguments = Rti._getInterfaceTypeArguments(unstarred);
    // This recognizes interface types instantiated with Top, which includes the
    // common case of interfaces that have no type parameters.
    // TODO(sra): Can we easily recognize other interface types instantiated to
    // bounds?
    if (JS('bool', '#.every(#)', arguments, RAW_DART_FUNCTION_REF(isTopType))) {
      String propertyName =
          '${JS_GET_NAME(JsGetName.OPERATOR_IS_PREFIX)}${name}';
      Rti._setSpecializedTestResource(testRti, propertyName);
      if (name == JS_GET_NAME(JsGetName.LIST_CLASS_TYPE_NAME)) {
        return _finishIsFn(
            testRti, object, RAW_DART_FUNCTION_REF(_isListTestViaProperty));
      }
      return _finishIsFn(
          testRti, object, RAW_DART_FUNCTION_REF(_isTestViaProperty));
    }
    // fall through to general implementation.
  } else if (Rti._getKind(testRti) == Rti.kindQuestion) {
    return _finishIsFn(testRti, object,
        RAW_DART_FUNCTION_REF(_generalNullableIsTestImplementation));
  }
  return _finishIsFn(
      testRti, object, RAW_DART_FUNCTION_REF(_generalIsTestImplementation));
}

@pragma('dart2js:noInline') // Slightly smaller code.
bool _finishIsFn(Rti testRti, Object? object, Object? isFn) {
  Rti._setIsTestFunction(testRti, isFn);
  return Rti._isCheck(testRti, object);
}

Object? _simpleSpecializedIsTest(Rti testRti) {
  // Note: We must not match `Never` below.
  var isFn = null;
  if (_Utils.isIdentical(testRti, TYPE_REF<int>())) {
    isFn = RAW_DART_FUNCTION_REF(_isInt);
  } else if (_Utils.isIdentical(testRti, TYPE_REF<double>()) ||
      _Utils.isIdentical(testRti, TYPE_REF<num>())) {
    isFn = RAW_DART_FUNCTION_REF(_isNum);
  } else if (_Utils.isIdentical(testRti, TYPE_REF<String>())) {
    isFn = RAW_DART_FUNCTION_REF(_isString);
  } else if (_Utils.isIdentical(testRti, TYPE_REF<bool>())) {
    isFn = RAW_DART_FUNCTION_REF(_isBool);
  }
  return isFn;
}

/// Called from generated code.
///
/// The first time this default `_as` method is called, it replaces itself with
/// a specialized version.
Object? _installSpecializedAsCheck(Object? object) {
  // This static method is installed on an Rti object as a JavaScript instance
  // method. The Rti object is 'this'.
  Rti testRti = _Utils.asRti(JS('', 'this'));

  var asFn = RAW_DART_FUNCTION_REF(_generalAsCheckImplementation);
  if (isTopType(testRti)) {
    asFn = RAW_DART_FUNCTION_REF(_asTop);
  } else if (isObjectType(testRti)) {
    asFn = RAW_DART_FUNCTION_REF(_asObject);
  } else {
    if (JS_GET_FLAG('LEGACY') || isNullable(testRti)) {
      asFn = RAW_DART_FUNCTION_REF(_generalNullableAsCheckImplementation);
    }
  }

  Rti._setAsCheckFunction(testRti, asFn);
  return Rti._asCheck(testRti, object);
}

bool _nullIs(Rti testRti) {
  int kind = Rti._getKind(testRti);
  return isStrongTopType(testRti) ||
      isLegacyObjectType(testRti) ||
      _Utils.isIdentical(testRti, LEGACY_TYPE_REF<Never>()) ||
      kind == Rti.kindQuestion ||
      kind == Rti.kindFutureOr && _nullIs(Rti._getFutureOrArgument(testRti)) ||
      isNullType(testRti);
}

/// Called from generated code.
bool _generalIsTestImplementation(Object? object) {
  // This static method is installed on an Rti object as a JavaScript instance
  // method. The Rti object is 'this'.
  Rti testRti = _Utils.asRti(JS('', 'this'));
  if (object == null) return _nullIs(testRti);
  Rti objectRti = instanceOrFunctionType(object, testRti);
  return isSubtype(_theUniverse(), objectRti, testRti);
}

/// Specialized test for `x is T1` where `T1` has the form `T2?`.  Test is
/// compositional, calling `T2._is(object)`, so if `T2` has a specialized
/// version, the composed test will be fast (but not quite as fast as a
/// single-step specialization).
///
/// Called from generated code.
bool _generalNullableIsTestImplementation(Object? object) {
  if (object == null) return true;
  // This static method is installed on an Rti object as a JavaScript instance
  // method. The Rti object is 'this'.
  Rti testRti = _Utils.asRti(JS('', 'this'));
  Rti baseRti = Rti._getQuestionArgument(testRti);
  return Rti._isCheck(baseRti, object);
}

/// Called from generated code.
bool _isTestViaProperty(Object? object) {
  // This static method is installed on an Rti object as a JavaScript instance
  // method. The Rti object is 'this'.
  Rti testRti = _Utils.asRti(JS('', 'this'));
  if (object == null) return _nullIs(testRti);
  var tag = Rti._getSpecializedTestResource(testRti);

  // This test is redundant with getInterceptor below, but getInterceptor does
  // the tests in the wrong order for most tags, so it is usually faster to have
  // this check.
  if (_isDartObject(object)) {
    return JS('bool', '!!#[#]', object, tag);
  }

  var interceptor = getInterceptor(object);
  return JS('bool', '!!#[#]', interceptor, tag);
}

/// Specialized version of [_isTestViaProperty] with faster path for Arrays.
/// Called from generated code.
bool _isListTestViaProperty(Object? object) {
  // This static method is installed on an Rti object as a JavaScript instance
  // method. The Rti object is 'this'.
  Rti testRti = _Utils.asRti(JS('', 'this'));
  if (object == null) return _nullIs(testRti);

  // Only JavaScript values with `typeof x == "object"` are Dart Lists. Other
  // typeof results (undefined/string/number/boolean/function/symbol/bigint) are
  // all non-Lists. Dart `null`, being JavaScript `null` or JavaScript
  // `undefined`, is handled above.
  if (JS('bool', 'typeof # != "object"', object)) return false;

  if (_Utils.isArray(object)) return true;
  var tag = Rti._getSpecializedTestResource(testRti);

  // This test is redundant with getInterceptor below, but getInterceptor does
  // the tests in the wrong order for most tags, so it is usually faster to have
  // this check.
  if (_isDartObject(object)) {
    return JS('bool', '!!#[#]', object, tag);
  }

  var interceptor = getInterceptor(object);
  return JS('bool', '!!#[#]', interceptor, tag);
}

/// General unspecialized 'as' check that works for any type.
/// Called from generated code.
Object? _generalAsCheckImplementation(Object? object) {
  // This static method is installed on an Rti object as a JavaScript instance
  // method. The Rti object is 'this'.
  Rti testRti = _Utils.asRti(JS('', 'this'));
  if (object == null) {
    if (JS_GET_FLAG('LEGACY') || isNullable(testRti)) return object;
  } else if (Rti._isCheck(testRti, object)) return object;
  _failedAsCheck(object, testRti);
}

/// General 'as' check for types that accept `null`.
/// Called from generated code.
Object? _generalNullableAsCheckImplementation(Object? object) {
  // This static method is installed on an Rti object as a JavaScript instance
  // method. The Rti object is 'this'.
  Rti testRti = _Utils.asRti(JS('', 'this'));
  if (object == null) {
    return object;
  } else if (Rti._isCheck(testRti, object)) return object;
  _failedAsCheck(object, testRti);
}

void _failedAsCheck(Object? object, Rti testRti) {
  Rti objectRti = instanceOrFunctionType(object, testRti);
  String message =
      _Error.compose(object, objectRti, _rtiToString(testRti, null));
  throw _TypeError.fromMessage(message);
}

/// Called from generated code.
Rti checkTypeBound(Rti type, Rti bound, String variable, String methodName) {
  if (isSubtype(_theUniverse(), type, bound)) return type;
  String message = "The type argument '${_rtiToString(type, null)}' is not"
      " a subtype of the type variable bound '${_rtiToString(bound, null)}'"
      " of type variable '$variable' in '$methodName'.";
  throw _TypeError.fromMessage(message);
}

/// Called from generated code.
throwTypeError(String message) {
  throw _TypeError.fromMessage(message);
}

/// Base class to _TypeError.
class _Error extends Error {
  final String _message;
  _Error(this._message);

  static String compose(
      Object? object, Rti? objectRti, String checkedTypeDescription) {
    String objectDescription = Error.safeToString(object);
    objectRti ??= instanceType(object);
    String objectTypeDescription = _rtiToString(objectRti, null);
    return "${objectDescription}:"
        " type '${objectTypeDescription}'"
        " is not a subtype of type '${checkedTypeDescription}'";
  }

  @override
  String toString() => _message;
}

class _TypeError extends _Error implements TypeError, CastError {
  _TypeError.fromMessage(String message) : super('TypeError: $message');

  factory _TypeError.forType(object, String type) {
    return _TypeError.fromMessage(_Error.compose(object, null, type));
  }

  @override
  String get message => _message;
}

// Specializations.
//
// Specializations can be placed on Rti objects as the _as and _is
// 'methods'. They can also be called directly called from generated code.

/// Specialization for 'is Object'.
/// Called from generated code via Rti `_is` method.
bool _isObject(Object? object) {
  return object != null;
}

/// Specialization for 'as Object'.
/// Called from generated code via Rti `_as` method.
Object? _asObject(Object? object) {
  if (JS_GET_FLAG('LEGACY') || object != null) return object;
  throw _TypeError.forType(object, 'Object');
}

/// Specialization for 'is dynamic' and other top types.
/// Called from generated code via Rti `_is` method.
bool _isTop(Object? object) {
  return true;
}

/// Specialization for 'as dynamic' and other top types.
/// Called from generated code via Rti `_as` methods.
Object? _asTop(Object? object) {
  return object;
}

/// Specialization for 'is bool'.
/// Called from generated code.
bool _isBool(Object? object) {
  return true == object || false == object;
}

// TODO(fishythefish): Change `dynamic` to `Object?` below once promotion works.

/// Specialization for 'as bool'.
/// Called from generated code.
bool _asBool(Object? object) {
  if (true == object) return true;
  if (false == object) return false;
  throw _TypeError.forType(object, 'bool');
}

/// Specialization for 'as bool*'.
/// Called from generated code.
bool? _asBoolS(dynamic object) {
  if (true == object) return true;
  if (false == object) return false;
  if (object == null) return object;
  throw _TypeError.forType(object, 'bool');
}

/// Specialization for 'as bool?'.
/// Called from generated code.
bool? _asBoolQ(dynamic object) {
  if (true == object) return true;
  if (false == object) return false;
  if (object == null) return object;
  throw _TypeError.forType(object, 'bool?');
}

/// Specialization for 'as double'.
/// Called from generated code.
double _asDouble(Object? object) {
  if (_isNum(object)) return _Utils.asDouble(object);
  throw _TypeError.forType(object, 'double');
}

/// Specialization for 'as double*'.
/// Called from generated code.
double? _asDoubleS(dynamic object) {
  if (_isNum(object)) return _Utils.asDouble(object);
  if (object == null) return object;
  throw _TypeError.forType(object, 'double');
}

/// Specialization for 'as double?'.
/// Called from generated code.
double? _asDoubleQ(dynamic object) {
  if (_isNum(object)) return _Utils.asDouble(object);
  if (object == null) return object;
  throw _TypeError.forType(object, 'double?');
}

/// Specialization for 'is int'.
/// Called from generated code.
bool _isInt(Object? object) {
  return JS('bool', 'typeof # == "number"', object) &&
      JS('bool', 'Math.floor(#) === #', object, object);
}

/// Specialization for 'as int'.
/// Called from generated code.
int _asInt(Object? object) {
  if (_isInt(object)) return _Utils.asInt(object);
  throw _TypeError.forType(object, 'int');
}

/// Specialization for 'as int*'.
/// Called from generated code.
int? _asIntS(dynamic object) {
  if (_isInt(object)) return _Utils.asInt(object);
  if (object == null) return object;
  throw _TypeError.forType(object, 'int');
}

/// Specialization for 'as int?'.
/// Called from generated code.
int? _asIntQ(dynamic object) {
  if (_isInt(object)) return _Utils.asInt(object);
  if (object == null) return object;
  throw _TypeError.forType(object, 'int?');
}

/// Specialization for 'is num' and 'is double'.
/// Called from generated code.
bool _isNum(Object? object) {
  return JS('bool', 'typeof # == "number"', object);
}

/// Specialization for 'as num'.
/// Called from generated code.
num _asNum(Object? object) {
  if (_isNum(object)) return _Utils.asNum(object);
  throw _TypeError.forType(object, 'num');
}

/// Specialization for 'as num*'.
/// Called from generated code.
num? _asNumS(dynamic object) {
  if (_isNum(object)) return _Utils.asNum(object);
  if (object == null) return object;
  throw _TypeError.forType(object, 'num');
}

/// Specialization for 'as num?'.
/// Called from generated code.
num? _asNumQ(dynamic object) {
  if (_isNum(object)) return _Utils.asNum(object);
  if (object == null) return object;
  throw _TypeError.forType(object, 'num?');
}

/// Specialization for 'is String'.
/// Called from generated code.
bool _isString(Object? object) {
  return JS('bool', 'typeof # == "string"', object);
}

/// Specialization for 'as String'.
/// Called from generated code.
String _asString(Object? object) {
  if (_isString(object)) return _Utils.asString(object);
  throw _TypeError.forType(object, 'String');
}

/// Specialization for 'as String*'.
/// Called from generated code.
String? _asStringS(dynamic object) {
  if (_isString(object)) return _Utils.asString(object);
  if (object == null) return object;
  throw _TypeError.forType(object, 'String');
}

/// Specialization for 'as String?'.
/// Called from generated code.
String? _asStringQ(dynamic object) {
  if (_isString(object)) return _Utils.asString(object);
  if (object == null) return object;
  throw _TypeError.forType(object, 'String?');
}

String _rtiArrayToString(Object? array, List<String>? genericContext) {
  String s = '', sep = '';
  for (int i = 0; i < _Utils.arrayLength(array); i++) {
    s += sep +
        _rtiToString(_Utils.asRti(_Utils.arrayAt(array, i)), genericContext);
    sep = ', ';
  }
  return s;
}

String _functionRtiToString(Rti functionType, List<String>? genericContext,
    {Object? bounds = null}) {
  String typeParametersText = '';
  int? outerContextLength;

  if (bounds != null) {
    int boundsLength = _Utils.arrayLength(bounds);
    if (genericContext == null) {
      genericContext = <String>[];
    } else {
      outerContextLength = genericContext.length;
    }
    int offset = genericContext.length;
    for (int i = boundsLength; i > 0; i--) {
      genericContext.add('T${offset + i}');
    }

    String typeSep = '';
    typeParametersText = '<';
    for (int i = 0; i < boundsLength; i++) {
      typeParametersText += typeSep;
      typeParametersText += genericContext[genericContext.length - 1 - i];
      Rti boundRti = _Utils.asRti(_Utils.arrayAt(bounds, i));
      if (!isTopType(boundRti)) {
        typeParametersText +=
            ' extends ' + _rtiToString(boundRti, genericContext);
      }
      typeSep = ', ';
    }
    typeParametersText += '>';
  }

  Rti returnType = Rti._getReturnType(functionType);
  _FunctionParameters parameters = Rti._getFunctionParameters(functionType);
  var requiredPositional =
      _FunctionParameters._getRequiredPositional(parameters);
  int requiredPositionalLength = _Utils.arrayLength(requiredPositional);
  var optionalPositional =
      _FunctionParameters._getOptionalPositional(parameters);
  int optionalPositionalLength = _Utils.arrayLength(optionalPositional);
  var named = _FunctionParameters._getNamed(parameters);
  int namedLength = _Utils.arrayLength(named);
  assert(optionalPositionalLength == 0 || namedLength == 0);

  String returnTypeText = _rtiToString(returnType, genericContext);

  String argumentsText = '';
  String sep = '';
  for (int i = 0; i < requiredPositionalLength; i++) {
    argumentsText += sep +
        _rtiToString(_Utils.asRti(_Utils.arrayAt(requiredPositional, i)),
            genericContext);
    sep = ', ';
  }

  if (optionalPositionalLength > 0) {
    argumentsText += sep + '[';
    sep = '';
    for (int i = 0; i < optionalPositionalLength; i++) {
      argumentsText += sep +
          _rtiToString(_Utils.asRti(_Utils.arrayAt(optionalPositional, i)),
              genericContext);
      sep = ', ';
    }
    argumentsText += ']';
  }

  if (namedLength > 0) {
    argumentsText += sep + '{';
    sep = '';
    for (int i = 0; i < namedLength; i += 3) {
      argumentsText += sep;
      if (_Utils.asBool(_Utils.arrayAt(named, i + 1))) {
        argumentsText += 'required ';
      }
      argumentsText += _rtiToString(
              _Utils.asRti(_Utils.arrayAt(named, i + 2)), genericContext) +
          ' ' +
          _Utils.asString(_Utils.arrayAt(named, i));
      sep = ', ';
    }
    argumentsText += '}';
  }

  if (outerContextLength != null) {
    // Pop all of the generic type parameters.
    JS('', '#.length = #', genericContext!, outerContextLength);
  }

  // TODO(fishythefish): Below is the same format as the VM. Change to:
  //
  //     return '${returnTypeText} Function${typeParametersText}(${argumentsText})';
  //
  return '${typeParametersText}(${argumentsText}) => ${returnTypeText}';
}

String _rtiToString(Rti rti, List<String>? genericContext) {
  int kind = Rti._getKind(rti);

  if (kind == Rti.kindErased) return 'erased';
  if (kind == Rti.kindDynamic) return 'dynamic';
  if (kind == Rti.kindVoid) return 'void';
  if (kind == Rti.kindNever) return 'Never';
  if (kind == Rti.kindAny) return 'any';

  if (kind == Rti.kindStar) {
    Rti starArgument = Rti._getStarArgument(rti);
    String s = _rtiToString(starArgument, genericContext);
    if (JS_GET_FLAG('PRINT_LEGACY_STARS')) {
      int argumentKind = Rti._getKind(starArgument);
      if (argumentKind == Rti.kindFunction ||
          argumentKind == Rti.kindGenericFunction) {
        s = '(' + s + ')';
      }
      return s + '*';
    } else {
      return s;
    }
  }

  if (kind == Rti.kindQuestion) {
    Rti questionArgument = Rti._getQuestionArgument(rti);
    String s = _rtiToString(questionArgument, genericContext);
    int argumentKind = Rti._getKind(questionArgument);
    if (argumentKind == Rti.kindFunction ||
        argumentKind == Rti.kindGenericFunction) {
      s = '(' + s + ')';
    }
    return s + '?';
  }

  if (kind == Rti.kindFutureOr) {
    Rti futureOrArgument = Rti._getFutureOrArgument(rti);
    return 'FutureOr<${_rtiToString(futureOrArgument, genericContext)}>';
  }

  if (kind == Rti.kindInterface) {
    String name = Rti._getInterfaceName(rti);
    name = _unminifyOrTag(name);
    var arguments = Rti._getInterfaceTypeArguments(rti);
    if (arguments.length > 0) {
      name += '<' + _rtiArrayToString(arguments, genericContext) + '>';
    }
    return name;
  }

  if (kind == Rti.kindFunction) {
    return _functionRtiToString(rti, genericContext);
  }

  if (kind == Rti.kindGenericFunction) {
    Rti baseFunctionType = Rti._getGenericFunctionBase(rti);
    var bounds = Rti._getGenericFunctionBounds(rti);
    return _functionRtiToString(baseFunctionType, genericContext,
        bounds: bounds);
  }

  if (kind == Rti.kindGenericFunctionParameter) {
    var context = genericContext!;
    int index = Rti._getGenericFunctionParameterIndex(rti);
    return context[context.length - 1 - index];
  }

  return '?';
}

String _unminifyOrTag(String rawClassName) {
  String? preserved = unmangleGlobalNameIfPreservedAnyways(rawClassName);
  if (preserved != null) return preserved;
  return JS_GET_FLAG('MINIFIED') ? 'minified:$rawClassName' : rawClassName;
}

String _rtiArrayToDebugString(Object? array) {
  String s = '[', sep = '';
  for (int i = 0; i < _Utils.arrayLength(array); i++) {
    s += sep + _rtiToDebugString(_Utils.asRti(_Utils.arrayAt(array, i)));
    sep = ', ';
  }
  return s + ']';
}

String functionParametersToString(_FunctionParameters parameters) {
  String s = '(', sep = '';
  var requiredPositional =
      _FunctionParameters._getRequiredPositional(parameters);
  int requiredPositionalLength = _Utils.arrayLength(requiredPositional);
  var optionalPositional =
      _FunctionParameters._getOptionalPositional(parameters);
  int optionalPositionalLength = _Utils.arrayLength(optionalPositional);
  var named = _FunctionParameters._getNamed(parameters);
  int namedLength = _Utils.arrayLength(named);
  assert(optionalPositionalLength == 0 || namedLength == 0);

  for (int i = 0; i < requiredPositionalLength; i++) {
    s += sep +
        _rtiToDebugString(_Utils.asRti(_Utils.arrayAt(requiredPositional, i)));
    sep = ', ';
  }

  if (optionalPositionalLength > 0) {
    s += sep + '[';
    sep = '';
    for (int i = 0; i < optionalPositionalLength; i++) {
      s += sep +
          _rtiToDebugString(
              _Utils.asRti(_Utils.arrayAt(optionalPositional, i)));
      sep = ', ';
    }
    s += ']';
  }

  if (namedLength > 0) {
    s += sep + '{';
    sep = '';
    for (int i = 0; i < namedLength; i += 3) {
      s += sep;
      if (_Utils.asBool(_Utils.arrayAt(named, i + 1))) {
        s += 'required ';
      }
      s += _rtiToDebugString(_Utils.asRti(_Utils.arrayAt(named, i + 2))) +
          ' ' +
          _Utils.asString(_Utils.arrayAt(named, i));
      sep = ', ';
    }
    s += '}';
  }

  return s + ')';
}

String _rtiToDebugString(Rti rti) {
  int kind = Rti._getKind(rti);

  if (kind == Rti.kindErased) return 'erased';
  if (kind == Rti.kindDynamic) return 'dynamic';
  if (kind == Rti.kindVoid) return 'void';
  if (kind == Rti.kindNever) return 'Never';
  if (kind == Rti.kindAny) return 'any';

  if (kind == Rti.kindStar) {
    Rti starArgument = Rti._getStarArgument(rti);
    return 'star(${_rtiToDebugString(starArgument)})';
  }

  if (kind == Rti.kindQuestion) {
    Rti questionArgument = Rti._getQuestionArgument(rti);
    return 'question(${_rtiToDebugString(questionArgument)})';
  }

  if (kind == Rti.kindFutureOr) {
    Rti futureOrArgument = Rti._getFutureOrArgument(rti);
    return 'FutureOr(${_rtiToDebugString(futureOrArgument)})';
  }

  if (kind == Rti.kindInterface) {
    String name = Rti._getInterfaceName(rti);
    var arguments = Rti._getInterfaceTypeArguments(rti);
    if (_Utils.arrayLength(arguments) == 0) {
      return 'interface("$name")';
    } else {
      return 'interface("$name", ${_rtiArrayToDebugString(arguments)})';
    }
  }

  if (kind == Rti.kindBinding) {
    Rti base = Rti._getBindingBase(rti);
    var arguments = Rti._getBindingArguments(rti);
    return 'binding(${_rtiToDebugString(base)}, ${_rtiArrayToDebugString(arguments)})';
  }

  if (kind == Rti.kindFunction) {
    Rti returnType = Rti._getReturnType(rti);
    _FunctionParameters parameters = Rti._getFunctionParameters(rti);
    return 'function(${_rtiToDebugString(returnType)}, ${functionParametersToString(parameters)})';
  }

  if (kind == Rti.kindGenericFunction) {
    Rti baseFunctionType = Rti._getGenericFunctionBase(rti);
    var bounds = Rti._getGenericFunctionBounds(rti);
    return 'genericFunction(${_rtiToDebugString(baseFunctionType)}, ${_rtiArrayToDebugString(bounds)})';
  }

  if (kind == Rti.kindGenericFunctionParameter) {
    int index = Rti._getGenericFunctionParameterIndex(rti);
    return 'genericFunctionParameter($index)';
  }

  return 'other(kind=$kind)';
}

/// Class of static methods for the universe of Rti objects.
///
/// The universe is the manager object for the Rti instances.
///
/// The universe itself is allocated at startup before any types or Dart objects
/// can be created, so it does not have a Dart type.
class _Universe {
  _Universe._() {
    throw UnimplementedError('_Universe is static methods only');
  }

  @pragma('dart2js:noInline')
  static Object create() {
    // This needs to be kept in sync with `FragmentEmitter.createRtiUniverse` in
    // `fragment_emitter.dart`.
    return JS(
        '',
        '{'
            '#: new Map(),'
            '#: {},'
            '#: {},'
            '#: {},'
            '#: [],' // shared empty array.
            '}',
        RtiUniverseFieldNames.evalCache,
        RtiUniverseFieldNames.typeRules,
        RtiUniverseFieldNames.erasedTypes,
        RtiUniverseFieldNames.typeParameterVariances,
        RtiUniverseFieldNames.sharedEmptyArray);
  }

  // Field accessors.

  static Object evalCache(Object? universe) =>
      JS('', '#.#', universe, RtiUniverseFieldNames.evalCache);

  static Object typeRules(Object? universe) =>
      JS('', '#.#', universe, RtiUniverseFieldNames.typeRules);

  static Object erasedTypes(Object? universe) =>
      JS('', '#.#', universe, RtiUniverseFieldNames.erasedTypes);

  static Object typeParameterVariances(Object? universe) =>
      JS('', '#.#', universe, RtiUniverseFieldNames.typeParameterVariances);

  static Object? _findRule(Object? universe, String targetType) =>
      JS('', '#.#', typeRules(universe), targetType);

  static Object? findRule(Object? universe, String targetType) {
    var rule = _findRule(universe, targetType);
    while (_Utils.isString(rule)) {
      rule = _findRule(universe, _Utils.asString(rule));
    }
    return rule;
  }

  static Rti findErasedType(Object? universe, String cls) {
    var metadata = erasedTypes(universe);
    var probe = JS('', '#.#', metadata, cls);
    if (probe == null) {
      return eval(universe, cls, false);
    } else if (_Utils.isNum(probe)) {
      int length = _Utils.asInt(probe);
      Rti erased = _lookupErasedRti(universe);
      Object? arguments = _Utils.newArrayOrEmpty(length);
      for (int i = 0; i < length; i++) {
        _Utils.arraySetAt(arguments, i, erased);
      }
      Rti interface = _lookupInterfaceRti(universe, cls, arguments);
      JS('', '#.# = #', metadata, cls, interface);
      return interface;
    } else {
      return _Utils.asRti(probe);
    }
  }

  static Object? findTypeParameterVariances(Object? universe, String cls) =>
      JS('', '#.#', typeParameterVariances(universe), cls);

  static void addRules(Object? universe, Object? rules) =>
      _Utils.objectAssign(typeRules(universe), rules);

  static void addErasedTypes(Object? universe, Object? types) =>
      _Utils.objectAssign(erasedTypes(universe), types);

  static void addTypeParameterVariances(Object? universe, Object? variances) =>
      _Utils.objectAssign(typeParameterVariances(universe), variances);

  static JSArray sharedEmptyArray(Object? universe) => JS('JSUnmodifiableArray',
      '#.#', universe, RtiUniverseFieldNames.sharedEmptyArray);

  /// Evaluates [recipe] in the global environment.
  static Rti eval(Object? universe, String recipe, bool normalize) {
    var cache = evalCache(universe);
    var probe = _Utils.mapGet(cache, recipe);
    if (probe != null) return _Utils.asRti(probe);
    Rti rti = _parseRecipe(universe, null, recipe, normalize);
    _Utils.mapSet(cache, recipe, rti);
    return rti;
  }

  static Rti evalInEnvironment(
      Object? universe, Rti environment, String recipe) {
    var cache = Rti._getEvalCache(environment);
    if (cache == null) {
      cache = JS('', 'new Map()');
      Rti._setEvalCache(environment, cache);
    }
    var probe = _Utils.mapGet(cache, recipe);
    if (probe != null) return _Utils.asRti(probe);
    Rti rti = _parseRecipe(universe, environment, recipe, true);
    _Utils.mapSet(cache, recipe, rti);
    return rti;
  }

  static Rti bind(Object? universe, Rti environment, Rti argumentsRti) {
    var cache = Rti._getBindCache(environment);
    if (cache == null) {
      cache = JS('', 'new Map()');
      Rti._setBindCache(environment, cache);
    }
    String argumentsRecipe = Rti._getCanonicalRecipe(argumentsRti);
    var probe = _Utils.mapGet(cache, argumentsRecipe);
    if (probe != null) return _Utils.asRti(probe);
    var argumentsArray;
    if (Rti._getKind(argumentsRti) == Rti.kindBinding) {
      argumentsArray = Rti._getBindingArguments(argumentsRti);
    } else {
      argumentsArray = JS('', '[#]', argumentsRti);
    }
    Rti rti = _lookupBindingRti(universe, environment, argumentsArray);
    _Utils.mapSet(cache, argumentsRecipe, rti);
    return rti;
  }

  static Rti bind1(Object? universe, Rti environment, Rti argumentsRti) {
    throw UnimplementedError('_Universe.bind1');
  }

  static Rti evalTypeVariable(Object? universe, Rti environment, String name) {
    int kind = Rti._getKind(environment);
    if (kind == Rti.kindBinding) {
      environment = Rti._getBindingBase(environment);
    }

    String interfaceName = Rti._getInterfaceName(environment);
    var rule = _Universe.findRule(universe, interfaceName);
    assert(rule != null);
    String? recipe = TypeRule.lookupTypeVariable(rule, name);
    if (recipe == null) {
      throw 'No "$name" in "${Rti._getCanonicalRecipe(environment)}"';
    }
    return _Universe.evalInEnvironment(universe, environment, recipe);
  }

  static Rti _parseRecipe(
      Object? universe, Object? environment, String recipe, bool normalize) {
    var parser = _Parser.create(universe, environment, recipe, normalize);
    Rti rti = _Parser.parse(parser);
    return rti;
  }

  static Rti _installTypeTests(Object? universe, Rti rti) {
    // Set up methods to perform type tests. The general as-check methods use
    // the is-test method. The is-test method on first use overwrites itself,
    // and possibly the as-check methods, with a specialized version.
    var asFn = RAW_DART_FUNCTION_REF(_installSpecializedAsCheck);
    var isFn = RAW_DART_FUNCTION_REF(_installSpecializedIsTest);
    Rti._setAsCheckFunction(rti, asFn);
    Rti._setIsTestFunction(rti, isFn);
    return rti;
  }

  static Rti _installRti(Object? universe, String key, Rti rti) {
    _Utils.mapSet(evalCache(universe), key, rti);
    return rti;
  }

  // These helpers are used for creating canonical recipes. The key feature of
  // the generated code is that it makes no reference to the constant pool,
  // which does not exist when the type$ pool is created.
  //
  // The strange association is so that usage like
  //
  //     s = _recipeJoin3(s, a, b);
  //
  // associates as `s+=(a+b)` rather than `s=s+a+b`. As recipe fragments are
  // small, this tends to create smaller cons-string trees.

  static String _recipeJoin(String s1, String s2) => JS_STRING_CONCAT(s1, s2);
  static String _recipeJoin3(String s1, String s2, String s3) =>
      JS_STRING_CONCAT(s1, JS_STRING_CONCAT(s2, s3));
  static String _recipeJoin4(String s1, String s2, String s3, String s4) =>
      JS_STRING_CONCAT(s1, JS_STRING_CONCAT(JS_STRING_CONCAT(s2, s3), s4));
  static String _recipeJoin5(
          String s1, String s2, String s3, String s4, String s5) =>
      JS_STRING_CONCAT(s1,
          JS_STRING_CONCAT(JS_STRING_CONCAT(JS_STRING_CONCAT(s2, s3), s4), s5));

  // For each kind of Rti there are three methods:
  //
  // * `lookupXXX` which takes the component parts and returns an existing Rti
  //   object if it exists.
  // * `canonicalRecipeOfXXX` that returns the compositional canonical recipe
  //   for the proposed type.
  // * `createXXX` to create the type if it does not exist.
  //
  // The create method performs normalization before allocating a new Rti. Cache
  // keys are not normalized, so if multiple recipes normalize to the same type,
  // then their corresponding cache entries will point to the same value. This
  // prevents us from having to normalize on every lookup instead of every
  // allocation.

  static String _canonicalRecipeOfErased() => Recipe.pushErasedString;
  static String _canonicalRecipeOfDynamic() => Recipe.pushDynamicString;
  static String _canonicalRecipeOfVoid() => Recipe.pushVoidString;
  static String _canonicalRecipeOfNever() =>
      _recipeJoin(Recipe.pushNeverExtensionString, Recipe.extensionOpString);
  static String _canonicalRecipeOfAny() =>
      _recipeJoin(Recipe.pushAnyExtensionString, Recipe.extensionOpString);

  static String _canonicalRecipeOfStar(Rti baseType) =>
      _recipeJoin(Rti._getCanonicalRecipe(baseType), Recipe.wrapStarString);
  static String _canonicalRecipeOfQuestion(Rti baseType) =>
      _recipeJoin(Rti._getCanonicalRecipe(baseType), Recipe.wrapQuestionString);
  static String _canonicalRecipeOfFutureOr(Rti baseType) =>
      _recipeJoin(Rti._getCanonicalRecipe(baseType), Recipe.wrapFutureOrString);

  static String _canonicalRecipeOfGenericFunctionParameter(int index) =>
      _recipeJoin('$index', Recipe.genericFunctionTypeParameterIndexString);

  static Rti _lookupErasedRti(Object? universe) {
    return _lookupTerminalRti(
        universe, Rti.kindErased, _canonicalRecipeOfErased());
  }

  static Rti _lookupDynamicRti(Object? universe) {
    return _lookupTerminalRti(
        universe, Rti.kindDynamic, _canonicalRecipeOfDynamic());
  }

  static Rti _lookupVoidRti(Object? universe) {
    return _lookupTerminalRti(universe, Rti.kindVoid, _canonicalRecipeOfVoid());
  }

  static Rti _lookupNeverRti(Object? universe) {
    return _lookupTerminalRti(
        universe, Rti.kindNever, _canonicalRecipeOfNever());
  }

  static Rti _lookupAnyRti(Object? universe) {
    return _lookupTerminalRti(universe, Rti.kindAny, _canonicalRecipeOfAny());
  }

  static Rti _lookupTerminalRti(Object? universe, int kind, String key) {
    var cache = evalCache(universe);
    var probe = _Utils.mapGet(cache, key);
    if (probe != null) return _Utils.asRti(probe);
    return _installRti(universe, key, _createTerminalRti(universe, kind, key));
  }

  static Rti _createTerminalRti(Object? universe, int kind, String key) {
    Rti rti = Rti.allocate();
    Rti._setKind(rti, kind);
    Rti._setCanonicalRecipe(rti, key);
    return _installTypeTests(universe, rti);
  }

  static Rti _lookupStarRti(Object? universe, Rti baseType, bool normalize) {
    String key = _canonicalRecipeOfStar(baseType);
    var cache = evalCache(universe);
    var probe = _Utils.mapGet(cache, key);
    if (probe != null) return _Utils.asRti(probe);
    return _installRti(
        universe, key, _createStarRti(universe, baseType, key, normalize));
  }

  static Rti _createStarRti(
      Object? universe, Rti baseType, String key, bool normalize) {
    if (normalize) {
      int baseKind = Rti._getKind(baseType);
      if (isStrongTopType(baseType) ||
          isNullType(baseType) ||
          baseKind == Rti.kindQuestion ||
          baseKind == Rti.kindStar) {
        return baseType;
      }
    }
    Rti rti = Rti.allocate();
    Rti._setKind(rti, Rti.kindStar);
    Rti._setPrimary(rti, baseType);
    Rti._setCanonicalRecipe(rti, key);
    return _installTypeTests(universe, rti);
  }

  static Rti _lookupQuestionRti(
      Object? universe, Rti baseType, bool normalize) {
    String key = _canonicalRecipeOfQuestion(baseType);
    var cache = evalCache(universe);
    var probe = _Utils.mapGet(cache, key);
    if (probe != null) return _Utils.asRti(probe);
    return _installRti(
        universe, key, _createQuestionRti(universe, baseType, key, normalize));
  }

  static Rti _createQuestionRti(
      Object? universe, Rti baseType, String key, bool normalize) {
    if (normalize) {
      int baseKind = Rti._getKind(baseType);
      if (isStrongTopType(baseType) ||
          isNullType(baseType) ||
          baseKind == Rti.kindQuestion ||
          baseKind == Rti.kindFutureOr &&
              isNullable(Rti._getFutureOrArgument(baseType))) {
        return baseType;
      } else if (baseKind == Rti.kindNever ||
          _Utils.isIdentical(baseType, LEGACY_TYPE_REF<Never>())) {
        return TYPE_REF<Null>();
      } else if (baseKind == Rti.kindStar) {
        Rti starArgument = Rti._getStarArgument(baseType);
        int starArgumentKind = Rti._getKind(starArgument);
        if (starArgumentKind == Rti.kindFutureOr &&
            isNullable(Rti._getFutureOrArgument(starArgument))) {
          return starArgument;
        } else {
          return Rti._getQuestionFromStar(universe, baseType);
        }
      }
    }
    Rti rti = Rti.allocate();
    Rti._setKind(rti, Rti.kindQuestion);
    Rti._setPrimary(rti, baseType);
    Rti._setCanonicalRecipe(rti, key);
    return _installTypeTests(universe, rti);
  }

  static Rti _lookupFutureOrRti(
      Object? universe, Rti baseType, bool normalize) {
    String key = _canonicalRecipeOfFutureOr(baseType);
    var cache = evalCache(universe);
    var probe = _Utils.mapGet(cache, key);
    if (probe != null) return _Utils.asRti(probe);
    return _installRti(
        universe, key, _createFutureOrRti(universe, baseType, key, normalize));
  }

  static Rti _createFutureOrRti(
      Object? universe, Rti baseType, String key, bool normalize) {
    if (normalize) {
      int baseKind = Rti._getKind(baseType);
      if (isTopType(baseType) || isObjectType(baseType)) {
        return baseType;
      } else if (baseKind == Rti.kindNever) {
        return _lookupFutureRti(universe, baseType);
      } else if (isNullType(baseType)) {
        return TYPE_REF<Future<Null>?>();
      }
    }
    Rti rti = Rti.allocate();
    Rti._setKind(rti, Rti.kindFutureOr);
    Rti._setPrimary(rti, baseType);
    Rti._setCanonicalRecipe(rti, key);
    return _installTypeTests(universe, rti);
  }

  static Rti _lookupGenericFunctionParameterRti(Object? universe, int index) {
    String key = _canonicalRecipeOfGenericFunctionParameter(index);
    var cache = evalCache(universe);
    var probe = _Utils.mapGet(cache, key);
    if (probe != null) return _Utils.asRti(probe);
    return _installRti(universe, key,
        _createGenericFunctionParameterRti(universe, index, key));
  }

  static Rti _createGenericFunctionParameterRti(
      Object? universe, int index, String key) {
    Rti rti = Rti.allocate();
    Rti._setKind(rti, Rti.kindGenericFunctionParameter);
    Rti._setPrimary(rti, index);
    Rti._setCanonicalRecipe(rti, key);
    return _installTypeTests(universe, rti);
  }

  static String _canonicalRecipeJoin(Object? arguments) {
    String s = '', sep = '';
    int length = _Utils.arrayLength(arguments);
    for (int i = 0; i < length; i++) {
      Rti argument = _Utils.asRti(_Utils.arrayAt(arguments, i));
      String subrecipe = Rti._getCanonicalRecipe(argument);
      s = _recipeJoin3(s, sep, subrecipe);
      sep = Recipe.separatorString;
    }
    return s;
  }

  static String _canonicalRecipeJoinNamed(Object? arguments) {
    String s = '', sep = '';
    int length = _Utils.arrayLength(arguments);
    assert(_Utils.isMultipleOf(length, 3));
    for (int i = 0; i < length; i += 3) {
      String name = _Utils.asString(_Utils.arrayAt(arguments, i));
      bool isRequired = _Utils.asBool(_Utils.arrayAt(arguments, i + 1));
      String nameSep = isRequired
          ? Recipe.requiredNameSeparatorString
          : Recipe.nameSeparatorString;
      Rti type = _Utils.asRti(_Utils.arrayAt(arguments, i + 2));
      String subrecipe = Rti._getCanonicalRecipe(type);
      s = _recipeJoin5(s, sep, name, nameSep, subrecipe);
      sep = Recipe.separatorString;
    }
    return s;
  }

  static String _canonicalRecipeOfInterface(String name, Object? arguments) {
    assert(_Utils.isString(name));
    String s = _Utils.asString(name);
    int length = _Utils.arrayLength(arguments);
    if (length > 0) {
      s = _recipeJoin4(s, Recipe.startTypeArgumentsString,
          _canonicalRecipeJoin(arguments), Recipe.endTypeArgumentsString);
    }
    return s;
  }

  static Rti _lookupInterfaceRti(
      Object? universe, String name, Object? arguments) {
    String key = _canonicalRecipeOfInterface(name, arguments);
    var cache = evalCache(universe);
    var probe = _Utils.mapGet(cache, key);
    if (probe != null) return _Utils.asRti(probe);
    return _installRti(
        universe, key, _createInterfaceRti(universe, name, arguments, key));
  }

  static Rti _createInterfaceRti(
      Object? universe, String name, Object? typeArguments, String key) {
    Rti rti = Rti.allocate();
    Rti._setKind(rti, Rti.kindInterface);
    Rti._setPrimary(rti, name);
    Rti._setRest(rti, typeArguments);
    int length = _Utils.arrayLength(typeArguments);
    if (length > 0) {
      Rti._setPrecomputed1(rti, _Utils.arrayAt(typeArguments, 0));
    }
    Rti._setCanonicalRecipe(rti, key);
    return _installTypeTests(universe, rti);
  }

  static Rti _lookupFutureRti(Object? universe, Rti base) =>
      _lookupInterfaceRti(universe,
          JS_GET_NAME(JsGetName.FUTURE_CLASS_TYPE_NAME), JS('', '[#]', base));

  static String _canonicalRecipeOfBinding(Rti base, Object? arguments) {
    return _recipeJoin5(
        Rti._getCanonicalRecipe(base),
        // TODO(sra): Omit when base encoding is Rti without ToType:
        Recipe.toTypeString,
        Recipe.startTypeArgumentsString,
        _canonicalRecipeJoin(arguments),
        Recipe.endTypeArgumentsString);
  }

  /// [arguments] becomes owned by the created Rti.
  static Rti _lookupBindingRti(Object? universe, Rti base, Object? arguments) {
    Rti newBase = base;
    var newArguments = arguments;
    if (Rti._getKind(base) == Rti.kindBinding) {
      newBase = Rti._getBindingBase(base);
      newArguments =
          _Utils.arrayConcat(Rti._getBindingArguments(base), arguments);
    }
    String key = _canonicalRecipeOfBinding(newBase, newArguments);
    var cache = evalCache(universe);
    var probe = _Utils.mapGet(cache, key);
    if (probe != null) return _Utils.asRti(probe);
    return _installRti(
        universe, key, _createBindingRti(universe, newBase, newArguments, key));
  }

  static Rti _createBindingRti(
      Object? universe, Rti base, Object? arguments, String key) {
    Rti rti = Rti.allocate();
    Rti._setKind(rti, Rti.kindBinding);
    Rti._setPrimary(rti, base);
    Rti._setRest(rti, arguments);
    Rti._setCanonicalRecipe(rti, key);
    return _installTypeTests(universe, rti);
  }

  static String _canonicalRecipeOfFunction(
          Rti returnType, _FunctionParameters parameters) =>
      _recipeJoin(Rti._getCanonicalRecipe(returnType),
          _canonicalRecipeOfFunctionParameters(parameters));

  static String _canonicalRecipeOfFunctionParameters(
      _FunctionParameters parameters) {
    var requiredPositional =
        _FunctionParameters._getRequiredPositional(parameters);
    int requiredPositionalLength = _Utils.arrayLength(requiredPositional);
    var optionalPositional =
        _FunctionParameters._getOptionalPositional(parameters);
    int optionalPositionalLength = _Utils.arrayLength(optionalPositional);
    var named = _FunctionParameters._getNamed(parameters);
    int namedLength = _Utils.arrayLength(named);
    assert(optionalPositionalLength == 0 || namedLength == 0);

    String recipe = _recipeJoin(Recipe.startFunctionArgumentsString,
        _canonicalRecipeJoin(requiredPositional));

    if (optionalPositionalLength > 0) {
      String sep = requiredPositionalLength > 0 ? Recipe.separatorString : '';
      recipe = _recipeJoin5(
          recipe,
          sep,
          Recipe.startOptionalGroupString,
          _canonicalRecipeJoin(optionalPositional),
          Recipe.endOptionalGroupString);
    }

    if (namedLength > 0) {
      String sep = requiredPositionalLength > 0 ? Recipe.separatorString : '';
      recipe = _recipeJoin5(recipe, sep, Recipe.startNamedGroupString,
          _canonicalRecipeJoinNamed(named), Recipe.endNamedGroupString);
    }

    return _recipeJoin(recipe, Recipe.endFunctionArgumentsString);
  }

  static Rti _lookupFunctionRti(
      Object? universe, Rti returnType, _FunctionParameters parameters) {
    String key = _canonicalRecipeOfFunction(returnType, parameters);
    var cache = evalCache(universe);
    var probe = _Utils.mapGet(cache, key);
    if (probe != null) return _Utils.asRti(probe);
    return _installRti(universe, key,
        _createFunctionRti(universe, returnType, parameters, key));
  }

  static Rti _createFunctionRti(Object? universe, Rti returnType,
      _FunctionParameters parameters, String key) {
    Rti rti = Rti.allocate();
    Rti._setKind(rti, Rti.kindFunction);
    Rti._setPrimary(rti, returnType);
    Rti._setRest(rti, parameters);
    Rti._setCanonicalRecipe(rti, key);
    return _installTypeTests(universe, rti);
  }

  static String _canonicalRecipeOfGenericFunction(
          Rti baseFunctionType, Object? bounds) =>
      _recipeJoin4(
          Rti._getCanonicalRecipe(baseFunctionType),
          Recipe.startTypeArgumentsString,
          _canonicalRecipeJoin(bounds),
          Recipe.endTypeArgumentsString);

  static Rti _lookupGenericFunctionRti(
      Object? universe, Rti baseFunctionType, Object? bounds, bool normalize) {
    String key = _canonicalRecipeOfGenericFunction(baseFunctionType, bounds);
    var cache = evalCache(universe);
    var probe = _Utils.mapGet(cache, key);
    if (probe != null) return _Utils.asRti(probe);
    return _installRti(
        universe,
        key,
        _createGenericFunctionRti(
            universe, baseFunctionType, bounds, key, normalize));
  }

  static Rti _createGenericFunctionRti(Object? universe, Rti baseFunctionType,
      Object? bounds, String key, bool normalize) {
    if (normalize) {
      int length = _Utils.arrayLength(bounds);
      int count = 0;
      Object? typeArguments = _Utils.newArrayOrEmpty(length);
      for (int i = 0; i < length; i++) {
        Rti bound = _Utils.asRti(_Utils.arrayAt(bounds, i));
        if (Rti._getKind(bound) == Rti.kindNever) {
          _Utils.arraySetAt(typeArguments, i, bound);
          count++;
        }
      }
      if (count > 0) {
        var substitutedBase =
            _substitute(universe, baseFunctionType, typeArguments, 0);
        var substitutedBounds =
            _substituteArray(universe, bounds, typeArguments, 0);
        return _lookupGenericFunctionRti(
            universe,
            substitutedBase,
            substitutedBounds,
            _Utils.isNotIdentical(bounds, substitutedBounds));
      }
    }
    Rti rti = Rti.allocate();
    Rti._setKind(rti, Rti.kindGenericFunction);
    Rti._setPrimary(rti, baseFunctionType);
    Rti._setRest(rti, bounds);
    Rti._setCanonicalRecipe(rti, key);
    return _installTypeTests(universe, rti);
  }
}

/// Class of static methods implementing recipe parser.
///
/// The recipe is a sequence of operations on a stack machine. The operations
/// are described below using the format
///
///      operation: stack elements before --- stack elements after
///
/// integer:  --- integer-value
///
/// identifier:  --- string-value
///
/// identifier-with-one-period:  --- type-variable-value
///
///   Period may be in any position, including first and last e.g. `.x`.
///
/// ',':  ---
///
///   Ignored. Used to separate elements.
///
/// ';': item  ---  ToType(item)
///
///   Used to separate elements.
///
/// '#': --- erasedType
///
/// '@': --- dynamicType
///
/// '~': --- voidType
///
/// '?':  type  ---  type?
///
/// '&':  0  ---  NeverType
/// '&':  1  ---  anyType
///
///   Escape op-code with small integer values for encoding rare operations.
///
/// '<':  --- position
///
///   Saves (pushes) position register, sets position register to end of stack.
///
/// '>':  name saved-position type ... type  ---  name<type, ..., type>
/// '>':  type saved-position type ... type  ---  binding(type, type, ..., type)
///
///   When first element is a String: Creates interface type from string 'name'
///   and the types pushed since the position register was last set. The types
///   are converted with a ToType operation. Restores position register to
///   previous saved value.
///
///   When first element is an Rti: Creates binding Rti wrapping the first
///   element. Binding Rtis are flattened: if the first element is a binding
///   Rti, the new binding Rti has the concatentation of the first element
///   bindings and new type.
///
///
/// The ToType operation coerces an item to an Rti. This saves encoding looking
/// up simple interface names and indexed variables.
///
///   ToType(string): Creates an interface Rti for the non-generic class.
///   ToType(integer): Indexes into the environment.
///   ToType(Rti): Same Rti
///
///
/// Notes on environments and indexing.
///
/// To avoid creating a binding Rti for a single function type parameter, the
/// type is passed without creating a 1-tuple object. This means that the
/// interface Rti for, say, `Map<num,dynamic>` serves as two environments with
/// different shapes. It is a class environment (K=num, V=dynamic) and a simple
/// 1-tuple environment. This is supported by index '0' refering to the whole
/// type, and '1 and '2' refering to K and V positionally:
///
///     interface("Map", [num,dynamic])
///     0                 1   2
///
/// Thus the type expression `List<K>` encodes as `List<1>` and in this
/// environment evaluates to `List<num>`. `List<Map<K,V>>` could be encoded as
/// either `List<0>` or `List<Map<1,2>>` (and in this environment evaluates to
/// `List<Map<num,dynamic>>`).
///
/// When `Map<num,dynamic>` is combined with a binding `<int,bool>` (e.g. inside
/// the instance method `Map<K,V>.cast<RK,RV>()`), '0' refers to the base object
/// of the binding, and then the numbering counts the bindings followed by the
/// class parameters.
///
///     binding(interface("Map", [num,dynamic]), [int, bool])
///             0                 3   4           1    2
///
/// Any environment can be reconstructed via a recipe. The above enviroment for
/// method `cast` can be constructed as the ground term
/// `Map<num,dynamic><int,bool>`, or (somewhat pointlessly) reconstructed via
/// `0<1,2>` or `Map<3,4><1,2>`. The ability to construct an environment
/// directly rather than via `bind` calls is used in folding sequences of `eval`
/// and `bind` calls.
///
/// While a single type parameter is passed as the type, multiple type
/// parameters are passed as a tuple. Tuples are encoded as a binding with an
/// ignored base. `dynamic` can be used as the base, giving an encoding like
/// `@<int,bool>`.
///
/// Bindings flatten, so `@<int><bool><num>` is the same as `@<int,bool,num>`.
///
/// The base of a binding does not have to have type parameters. Consider
/// `CodeUnits`, which mixes in `ListMixin<int>`. The environment inside of
/// `ListMixin.fold` (from the call `x.codeUnits.fold<bool>(...)`) would be
///
///     binding(interface("CodeUnits", []), [bool])
///
/// This can be encoded as `CodeUnits;<bool>` (note the `;` to force ToType to
/// avoid creating an interface type Rti with a single class type
/// argument). Metadata about the supertypes is used to resolve the recipe
/// `ListMixin.E` to `int`.

class _Parser {
  _Parser._() {
    throw UnimplementedError('_Parser is static methods only');
  }

  /// Creates a parser object for parsing a recipe against an environment in a
  /// universe.
  ///
  /// Marked as no-inline so the object literal is not cloned by inlining.
  @pragma('dart2js:noInline')
  static Object create(
      Object? universe, Object? environment, String recipe, bool normalize) {
    return JS(
        '',
        '{'
            'u:#,' // universe
            'e:#,' // environment
            'r:#,' // recipe
            's:[],' // stack
            'p:0,' // position of sequence start
            'n:#,' // whether to normalize
            '}',
        universe,
        environment,
        recipe,
        normalize);
  }

  // Field accessors for the parser.
  static Object universe(Object? parser) => JS('', '#.u', parser);
  static Rti? environment(Object? parser) => JS('Rti|Null', '#.e', parser);
  static String recipe(Object? parser) => JS('String', '#.r', parser);
  static Object stack(Object? parser) => JS('', '#.s', parser);
  static int position(Object? parser) => JS('int', '#.p', parser);
  static void setPosition(Object? parser, int p) {
    JS('', '#.p = #', parser, p);
  }

  static bool normalize(Object? parser) => JS('bool', '#.n', parser);

  static int charCodeAt(String s, int i) => JS('int', '#.charCodeAt(#)', s, i);
  static void push(Object? stack, Object? value) {
    JS('', '#.push(#)', stack, value);
  }

  static Object? pop(Object? stack) => JS('', '#.pop()', stack);

  static Rti parse(Object? parser) {
    String source = _Parser.recipe(parser);
    var stack = _Parser.stack(parser);
    int i = 0;
    while (i < source.length) {
      int ch = charCodeAt(source, i);
      if (Recipe.isDigit(ch)) {
        i = handleDigit(i + 1, ch, source, stack);
      } else if (Recipe.isIdentifierStart(ch)) {
        i = handleIdentifier(parser, i, source, stack, false);
      } else if (ch == Recipe.period) {
        i = handleIdentifier(parser, i, source, stack, true);
      } else {
        i++;
        switch (ch) {
          case Recipe.separator:
            break;

          case Recipe.nameSeparator:
            push(stack, false);
            break;

          case Recipe.requiredNameSeparator:
            push(stack, true);
            break;

          case Recipe.toType:
            push(stack,
                toType(universe(parser), environment(parser), pop(stack)));
            break;

          case Recipe.genericFunctionTypeParameterIndex:
            push(stack,
                toGenericFunctionParameter(universe(parser), pop(stack)));
            break;

          case Recipe.pushErased:
            push(stack, _Universe._lookupErasedRti(universe(parser)));
            break;

          case Recipe.pushDynamic:
            push(stack, _Universe._lookupDynamicRti(universe(parser)));
            break;

          case Recipe.pushVoid:
            push(stack, _Universe._lookupVoidRti(universe(parser)));
            break;

          case Recipe.startTypeArguments:
            pushStackFrame(parser, stack);
            break;

          case Recipe.endTypeArguments:
            handleTypeArguments(parser, stack);
            break;

          case Recipe.extensionOp:
            handleExtendedOperations(parser, stack);
            break;

          case Recipe.wrapStar:
            var u = universe(parser);
            push(
                stack,
                _Universe._lookupStarRti(
                    u,
                    toType(u, environment(parser), pop(stack)),
                    normalize(parser)));
            break;

          case Recipe.wrapQuestion:
            var u = universe(parser);
            push(
                stack,
                _Universe._lookupQuestionRti(
                    u,
                    toType(u, environment(parser), pop(stack)),
                    normalize(parser)));
            break;

          case Recipe.wrapFutureOr:
            var u = universe(parser);
            push(
                stack,
                _Universe._lookupFutureOrRti(
                    u,
                    toType(u, environment(parser), pop(stack)),
                    normalize(parser)));
            break;

          case Recipe.startFunctionArguments:
            pushStackFrame(parser, stack);
            break;

          case Recipe.endFunctionArguments:
            handleFunctionArguments(parser, stack);
            break;

          case Recipe.startOptionalGroup:
            pushStackFrame(parser, stack);
            break;

          case Recipe.endOptionalGroup:
            handleOptionalGroup(parser, stack);
            break;

          case Recipe.startNamedGroup:
            pushStackFrame(parser, stack);
            break;

          case Recipe.endNamedGroup:
            handleNamedGroup(parser, stack);
            break;

          default:
            JS('', 'throw "Bad character " + #', ch);
        }
      }
    }
    var item = pop(stack);
    return toType(universe(parser), environment(parser), item);
  }

  static void pushStackFrame(Object? parser, Object? stack) {
    push(stack, position(parser));
    setPosition(parser, _Utils.arrayLength(stack));
  }

  static int handleDigit(int i, int digit, String source, Object? stack) {
    int value = Recipe.digitValue(digit);
    for (; i < source.length; i++) {
      int ch = charCodeAt(source, i);
      if (!Recipe.isDigit(ch)) break;
      value = value * 10 + Recipe.digitValue(ch);
    }
    push(stack, value);
    return i;
  }

  static int handleIdentifier(
      Object? parser, int start, String source, Object? stack, bool hasPeriod) {
    int i = start + 1;
    for (; i < source.length; i++) {
      int ch = charCodeAt(source, i);
      if (ch == Recipe.period) {
        if (hasPeriod) break;
        hasPeriod = true;
      } else if (Recipe.isIdentifierStart(ch) || Recipe.isDigit(ch)) {
        // Accept.
      } else {
        break;
      }
    }
    String string = _Utils.substring(source, start, i);
    if (hasPeriod) {
      push(
          stack,
          _Universe.evalTypeVariable(
              universe(parser), environment(parser)!, string));
    } else {
      push(stack, string);
    }
    return i;
  }

  static void handleTypeArguments(Object? parser, Object? stack) {
    var universe = _Parser.universe(parser);
    var arguments = collectArray(parser, stack);
    var head = pop(stack);
    if (_Utils.isString(head)) {
      String name = _Utils.asString(head);
      push(stack, _Universe._lookupInterfaceRti(universe, name, arguments));
    } else {
      Rti base = toType(universe, environment(parser), head);
      switch (Rti._getKind(base)) {
        case Rti.kindFunction:
          push(
              stack,
              _Universe._lookupGenericFunctionRti(
                  universe, base, arguments, normalize(parser)));
          break;

        default:
          push(stack, _Universe._lookupBindingRti(universe, base, arguments));
          break;
      }
    }
  }

  static const int optionalPositionalSentinel = -1;
  static const int namedSentinel = -2;

  static void handleFunctionArguments(Object? parser, Object? stack) {
    var universe = _Parser.universe(parser);
    _FunctionParameters parameters = _FunctionParameters.allocate();
    Object? optionalPositional = _Universe.sharedEmptyArray(universe);
    Object? named = _Universe.sharedEmptyArray(universe);

    var head = pop(stack);
    if (_Utils.isNum(head)) {
      int sentinel = _Utils.asInt(head);
      switch (sentinel) {
        case optionalPositionalSentinel:
          optionalPositional = pop(stack);
          break;

        case namedSentinel:
          named = pop(stack);
          break;

        default:
          push(stack, head);
          break;
      }
    } else {
      push(stack, head);
    }

    _FunctionParameters._setRequiredPositional(
        parameters, collectArray(parser, stack));
    _FunctionParameters._setOptionalPositional(parameters, optionalPositional);
    _FunctionParameters._setNamed(parameters, named);
    Rti returnType = toType(universe, environment(parser), pop(stack));
    push(stack, _Universe._lookupFunctionRti(universe, returnType, parameters));
  }

  static void handleOptionalGroup(Object? parser, Object? stack) {
    var parameters = collectArray(parser, stack);
    push(stack, parameters);
    push(stack, optionalPositionalSentinel);
  }

  static void handleNamedGroup(Object? parser, Object? stack) {
    var parameters = collectNamed(parser, stack);
    push(stack, parameters);
    push(stack, namedSentinel);
  }

  static void handleExtendedOperations(Object? parser, Object? stack) {
    var top = pop(stack);
    if (0 == top) {
      push(stack, _Universe._lookupNeverRti(universe(parser)));
      return;
    }
    if (1 == top) {
      push(stack, _Universe._lookupAnyRti(universe(parser)));
      return;
    }
    throw AssertionError('Unexpected extended operation $top');
  }

  static JSArray collectArray(Object? parser, Object? stack) {
    var array = _Utils.arraySplice(stack, position(parser));
    toTypes(_Parser.universe(parser), environment(parser), array);
    setPosition(parser, _Utils.asInt(pop(stack)));
    return array;
  }

  static JSArray collectNamed(Object? parser, Object? stack) {
    var array = _Utils.arraySplice(stack, position(parser));
    toTypesNamed(_Parser.universe(parser), environment(parser), array);
    setPosition(parser, _Utils.asInt(pop(stack)));
    return array;
  }

  /// Coerce a stack item into an Rti object. Strings are converted to interface
  /// types, integers are looked up in the type environment.
  static Rti toType(Object? universe, Rti? environment, Object? item) {
    if (_Utils.isString(item)) {
      String name = _Utils.asString(item);
      return _Universe._lookupInterfaceRti(
          universe, name, _Universe.sharedEmptyArray(universe));
    } else if (_Utils.isNum(item)) {
      return _Parser.indexToType(universe, environment!, _Utils.asInt(item));
    } else {
      return _Utils.asRti(item);
    }
  }

  static void toTypes(Object? universe, Rti? environment, Object? items) {
    int length = _Utils.arrayLength(items);
    for (int i = 0; i < length; i++) {
      var item = _Utils.arrayAt(items, i);
      Rti type = toType(universe, environment, item);
      _Utils.arraySetAt(items, i, type);
    }
  }

  static void toTypesNamed(Object? universe, Rti? environment, Object? items) {
    int length = _Utils.arrayLength(items);
    assert(_Utils.isMultipleOf(length, 3));
    for (int i = 2; i < length; i += 3) {
      var item = _Utils.arrayAt(items, i);
      Rti type = toType(universe, environment, item);
      _Utils.arraySetAt(items, i, type);
    }
  }

  static Rti indexToType(Object? universe, Rti environment, int index) {
    int kind = Rti._getKind(environment);
    if (kind == Rti.kindBinding) {
      if (index == 0) return Rti._getBindingBase(environment);
      var typeArguments = Rti._getBindingArguments(environment);
      int len = _Utils.arrayLength(typeArguments);
      if (index <= len) {
        return _Utils.asRti(_Utils.arrayAt(typeArguments, index - 1));
      }
      // Is index into interface Rti in base.
      index -= len;
      environment = Rti._getBindingBase(environment);
      kind = Rti._getKind(environment);
    } else {
      if (index == 0) return environment;
    }
    if (kind != Rti.kindInterface) {
      throw AssertionError('Indexed base must be an interface type');
    }
    var typeArguments = Rti._getInterfaceTypeArguments(environment);
    int len = _Utils.arrayLength(typeArguments);
    if (index <= len) {
      return _Utils.asRti(_Utils.arrayAt(typeArguments, index - 1));
    }
    throw AssertionError('Bad index $index for $environment');
  }

  static Rti toGenericFunctionParameter(Object? universe, Object? item) {
    assert(_Utils.isNum(item));
    return _Universe._lookupGenericFunctionParameterRti(
        universe, _Utils.asInt(item));
  }
}

/// Represents the set of supertypes and type variable bindings for a given
/// target type. The target type itself is not stored on the [TypeRule].
class TypeRule {
  TypeRule._() {
    throw UnimplementedError("TypeRule is static methods only.");
  }

  static String? lookupTypeVariable(Object? rule, String typeVariable) =>
      JS('', '#.#', rule, typeVariable);

  static JSArray? lookupSupertype(Object? rule, String supertype) =>
      JS('', '#.#', rule, supertype);
}

// This needs to be kept in sync with `Variance` in `entities.dart`.
class Variance {
  // TODO(fishythefish): Try bitmask representation.
  static const int legacyCovariant = 0;
  static const int covariant = 1;
  static const int contravariant = 2;
  static const int invariant = 3;
}

// -------- Subtype tests ------------------------------------------------------

// Future entry point from compiled code.
bool isSubtype(Object? universe, Rti s, Rti t) {
  return _isSubtype(universe, s, null, t, null);
}

/// Based on
/// https://github.com/dart-lang/language/blob/master/resources/type-system/subtyping.md#rules
/// and https://github.com/dart-lang/language/pull/388.
/// In particular, the bulk of the structure is derived from the former
/// resource, with a few adaptations taken from the latter.
/// - We freely skip subcases which would have already been handled by a
/// previous case.
/// - Some rules are reordered in conjunction with the previous point to reduce
/// the amount of casework.
/// - Left Type Variable Bound in particular is split into two pieces: an
/// optimistic check performed early in the algorithm to reduce the number of
/// backtracking cases when a union appears on the right, and a pessimistic
/// check performed at the usual place in order to completely eliminate the
/// case.
/// - Function type rules are applied before interface type rules.
///
/// [s] is considered a legacy subtype of [t] if [s] would be a subtype of [t]
/// in a modification of the NNBD rules in which `?` on types were ignored, `*`
/// were added to each time, and `required` parameters were treated as
/// optional. In effect, `Never` is equivalent to `Null`, `Null` is restored to
/// the bottom of the type hierarchy, `Object` is treated as nullable, and
/// `required` is ignored on named parameters. This should provide the same
/// subtyping results as pre-NNBD Dart.
bool _isSubtype(Object? universe, Rti s, Object? sEnv, Rti t, Object? tEnv) {
  bool isLegacy = JS_GET_FLAG('LEGACY');

  // Reflexivity:
  if (_Utils.isIdentical(s, t)) return true;

  // Right Top:
  if (isTopType(t)) return true;

  int sKind = Rti._getKind(s);
  if (sKind == Rti.kindAny) return true;

  // Left Top:
  if (isStrongTopType(s)) return false;

  // Left Bottom:
  if (isBottomType(s)) return true;

  // Left Type Variable Bound 1:
  bool leftTypeVariable = sKind == Rti.kindGenericFunctionParameter;
  if (leftTypeVariable) {
    int index = Rti._getGenericFunctionParameterIndex(s);
    Rti bound = _Utils.asRti(_Utils.arrayAt(sEnv, index));
    if (_isSubtype(universe, bound, sEnv, t, tEnv)) return true;
  }

  int tKind = Rti._getKind(t);

  // Left Null:
  // Note: Interchanging the Left Null and Right Object rules allows us to
  // reduce casework.
  if (!isLegacy && isNullType(s)) {
    if (tKind == Rti.kindFutureOr) {
      return _isSubtype(universe, s, sEnv, Rti._getFutureOrArgument(t), tEnv);
    }
    return isNullType(t) || tKind == Rti.kindQuestion || tKind == Rti.kindStar;
  }

  // Right Object:
  if (!isLegacy && isObjectType(t)) {
    if (sKind == Rti.kindFutureOr) {
      return _isSubtype(universe, Rti._getFutureOrArgument(s), sEnv, t, tEnv);
    }
    if (sKind == Rti.kindStar) {
      return _isSubtype(universe, Rti._getStarArgument(s), sEnv, t, tEnv);
    }
    return sKind != Rti.kindQuestion;
  }

  // Left Legacy:
  if (sKind == Rti.kindStar) {
    return _isSubtype(universe, Rti._getStarArgument(s), sEnv, t, tEnv);
  }

  // Right Legacy:
  if (tKind == Rti.kindStar) {
    return _isSubtype(
        universe,
        s,
        sEnv,
        isLegacy
            ? Rti._getStarArgument(t)
            : Rti._getQuestionFromStar(universe, t),
        tEnv);
  }

  // Left FutureOr:
  if (sKind == Rti.kindFutureOr) {
    if (!_isSubtype(universe, Rti._getFutureOrArgument(s), sEnv, t, tEnv)) {
      return false;
    }
    return _isSubtype(
        universe, Rti._getFutureFromFutureOr(universe, s), sEnv, t, tEnv);
  }

  // Left Nullable:
  if (sKind == Rti.kindQuestion) {
    return (isLegacy ||
            _isSubtype(universe, TYPE_REF<Null>(), sEnv, t, tEnv)) &&
        _isSubtype(universe, Rti._getQuestionArgument(s), sEnv, t, tEnv);
  }

  // Type Variable Reflexivity 1 is subsumed by Reflexivity and therefore
  // elided.
  // Type Variable Reflexivity 2 does not apply at runtime.
  // Right Promoted Variable does not apply at runtime.

  // Right FutureOr:
  if (tKind == Rti.kindFutureOr) {
    if (_isSubtype(universe, s, sEnv, Rti._getFutureOrArgument(t), tEnv)) {
      return true;
    }
    return _isSubtype(
        universe, s, sEnv, Rti._getFutureFromFutureOr(universe, t), tEnv);
  }

  // Right Nullable:
  if (tKind == Rti.kindQuestion) {
    return (!isLegacy &&
            _isSubtype(universe, s, sEnv, TYPE_REF<Null>(), tEnv)) ||
        _isSubtype(universe, s, sEnv, Rti._getQuestionArgument(t), tEnv);
  }

  // Left Promoted Variable does not apply at runtime.

  // Left Type Variable Bound 2:
  if (leftTypeVariable) return false;

  // Function Type/Function:
  if ((sKind == Rti.kindFunction || sKind == Rti.kindGenericFunction) &&
      isFunctionType(t)) {
    return true;
  }

  // Positional Function Types + Named Function Types:
  // TODO(fishythefish): Disallow JavaScriptFunction as a subtype of function
  // types using features inaccessible from JavaScript.
  if (tKind == Rti.kindGenericFunction) {
    if (isJsFunctionType(s)) return true;
    if (sKind != Rti.kindGenericFunction) return false;

    var sBounds = Rti._getGenericFunctionBounds(s);
    var tBounds = Rti._getGenericFunctionBounds(t);
    int sLength = _Utils.arrayLength(sBounds);
    int tLength = _Utils.arrayLength(tBounds);
    if (sLength != tLength) return false;

    sEnv = sEnv == null ? sBounds : _Utils.arrayConcat(sBounds, sEnv);
    tEnv = tEnv == null ? tBounds : _Utils.arrayConcat(tBounds, tEnv);

    for (int i = 0; i < sLength; i++) {
      var sBound = _Utils.asRti(_Utils.arrayAt(sBounds, i));
      var tBound = _Utils.asRti(_Utils.arrayAt(tBounds, i));
      if (!_isSubtype(universe, sBound, sEnv, tBound, tEnv) ||
          !_isSubtype(universe, tBound, tEnv, sBound, sEnv)) {
        return false;
      }
    }

    return _isFunctionSubtype(universe, Rti._getGenericFunctionBase(s), sEnv,
        Rti._getGenericFunctionBase(t), tEnv);
  }
  if (tKind == Rti.kindFunction) {
    if (isJsFunctionType(s)) return true;
    if (sKind != Rti.kindFunction) return false;
    return _isFunctionSubtype(universe, s, sEnv, t, tEnv);
  }

  // Interface Compositionality + Super-Interface:
  if (sKind == Rti.kindInterface) {
    if (tKind != Rti.kindInterface) return false;
    return _isInterfaceSubtype(universe, s, sEnv, t, tEnv);
  }

  return false;
}

bool _isFunctionSubtype(
    Object? universe, Rti s, Object? sEnv, Rti t, Object? tEnv) {
  assert(Rti._getKind(s) == Rti.kindFunction);
  assert(Rti._getKind(t) == Rti.kindFunction);

  Rti sReturnType = Rti._getReturnType(s);
  Rti tReturnType = Rti._getReturnType(t);
  if (!_isSubtype(universe, sReturnType, sEnv, tReturnType, tEnv)) {
    return false;
  }

  _FunctionParameters sParameters = Rti._getFunctionParameters(s);
  _FunctionParameters tParameters = Rti._getFunctionParameters(t);

  var sRequiredPositional =
      _FunctionParameters._getRequiredPositional(sParameters);
  var tRequiredPositional =
      _FunctionParameters._getRequiredPositional(tParameters);
  int sRequiredPositionalLength = _Utils.arrayLength(sRequiredPositional);
  int tRequiredPositionalLength = _Utils.arrayLength(tRequiredPositional);
  if (sRequiredPositionalLength > tRequiredPositionalLength) return false;
  int requiredPositionalDelta =
      tRequiredPositionalLength - sRequiredPositionalLength;

  var sOptionalPositional =
      _FunctionParameters._getOptionalPositional(sParameters);
  var tOptionalPositional =
      _FunctionParameters._getOptionalPositional(tParameters);
  int sOptionalPositionalLength = _Utils.arrayLength(sOptionalPositional);
  int tOptionalPositionalLength = _Utils.arrayLength(tOptionalPositional);
  if (sRequiredPositionalLength + sOptionalPositionalLength <
      tRequiredPositionalLength + tOptionalPositionalLength) return false;

  for (int i = 0; i < sRequiredPositionalLength; i++) {
    Rti sParameter = _Utils.asRti(_Utils.arrayAt(sRequiredPositional, i));
    Rti tParameter = _Utils.asRti(_Utils.arrayAt(tRequiredPositional, i));
    if (!_isSubtype(universe, tParameter, tEnv, sParameter, sEnv)) {
      return false;
    }
  }

  for (int i = 0; i < requiredPositionalDelta; i++) {
    Rti sParameter = _Utils.asRti(_Utils.arrayAt(sOptionalPositional, i));
    Rti tParameter = _Utils.asRti(
        _Utils.arrayAt(tRequiredPositional, sRequiredPositionalLength + i));
    if (!_isSubtype(universe, tParameter, tEnv, sParameter, sEnv)) {
      return false;
    }
  }

  for (int i = 0; i < tOptionalPositionalLength; i++) {
    Rti sParameter = _Utils.asRti(
        _Utils.arrayAt(sOptionalPositional, requiredPositionalDelta + i));
    Rti tParameter = _Utils.asRti(_Utils.arrayAt(tOptionalPositional, i));
    if (!_isSubtype(universe, tParameter, tEnv, sParameter, sEnv)) {
      return false;
    }
  }

  var sNamed = _FunctionParameters._getNamed(sParameters);
  var tNamed = _FunctionParameters._getNamed(tParameters);
  int sNamedLength = _Utils.arrayLength(sNamed);
  int tNamedLength = _Utils.arrayLength(tNamed);

  int sIndex = 0;
  for (int tIndex = 0; tIndex < tNamedLength; tIndex += 3) {
    String tName = _Utils.asString(_Utils.arrayAt(tNamed, tIndex));
    while (true) {
      if (sIndex >= sNamedLength) return false;
      String sName = _Utils.asString(_Utils.arrayAt(sNamed, sIndex));
      sIndex += 3;
      if (_Utils.stringLessThan(tName, sName)) return false;
      bool sIsRequired = !JS_GET_FLAG('LEGACY') &&
          _Utils.asBool(_Utils.arrayAt(sNamed, sIndex - 2));
      if (_Utils.stringLessThan(sName, tName)) {
        if (sIsRequired) return false;
        continue;
      }
      bool tIsRequired = !JS_GET_FLAG('LEGACY') &&
          _Utils.asBool(_Utils.arrayAt(tNamed, tIndex + 1));
      if (sIsRequired && !tIsRequired) return false;
      Rti sType = _Utils.asRti(_Utils.arrayAt(sNamed, sIndex - 1));
      Rti tType = _Utils.asRti(_Utils.arrayAt(tNamed, tIndex + 2));
      if (!_isSubtype(universe, tType, tEnv, sType, sEnv)) return false;
      break;
    }
  }
  if (!JS_GET_FLAG('LEGACY')) {
    while (sIndex < sNamedLength) {
      if (_Utils.asBool(_Utils.arrayAt(sNamed, sIndex + 1))) return false;
      sIndex += 3;
    }
  }
  return true;
}

bool _isInterfaceSubtype(
    Object? universe, Rti s, Object? sEnv, Rti t, Object? tEnv) {
  String sName = Rti._getInterfaceName(s);
  String tName = Rti._getInterfaceName(t);

  while (sName != tName) {
    // The Super-Interface rule says that if [s] has superinterfaces C0,...,Cn,
    // then we need to check if for some i, Ci <: [t]. However, this requires us
    // to iterate over the superinterfaces. Instead, we can perform case
    // analysis on [t]. By this point, [t] can only be Never, a type variable,
    // or an interface type. (Bindings do not participate in subtype checks and
    // all other cases have been eliminated.) If [t] is not an interface, then
    // [s] </: [t]. Therefore, the only remaining case is that [t] is an
    // interface, so rather than iterating over the Ci, we can instead look up
    // [t] in our ruleset.
    // TODO(fishythefish): Handle variance correctly.

    var rule = _Universe._findRule(universe, sName);
    if (rule == null) return false;
    if (_Utils.isString(rule)) {
      sName = _Utils.asString(rule);
      continue;
    }

    var recipes = TypeRule.lookupSupertype(rule, tName);
    if (recipes == null) return false;
    int length = _Utils.arrayLength(recipes);
    Object? supertypeArgs = _Utils.newArrayOrEmpty(length);
    for (int i = 0; i < length; i++) {
      String recipe = _Utils.asString(_Utils.arrayAt(recipes, i));
      Rti supertypeArg = _Universe.evalInEnvironment(universe, s, recipe);
      _Utils.arraySetAt(supertypeArgs, i, supertypeArg);
    }
    var tArgs = Rti._getInterfaceTypeArguments(t);
    return _areArgumentsSubtypes(
        universe, supertypeArgs, null, sEnv, tArgs, tEnv);
  }

  // Interface Compositionality:
  assert(sName == tName);
  var sArgs = Rti._getInterfaceTypeArguments(s);
  var tArgs = Rti._getInterfaceTypeArguments(t);
  var sVariances;
  if (JS_GET_FLAG("VARIANCE")) {
    sVariances = _Universe.findTypeParameterVariances(universe, sName);
  }
  return _areArgumentsSubtypes(universe, sArgs, sVariances, sEnv, tArgs, tEnv);
}

bool _areArgumentsSubtypes(Object? universe, Object? sArgs, Object? sVariances,
    Object? sEnv, Object? tArgs, Object? tEnv) {
  int length = _Utils.arrayLength(sArgs);
  assert(length == _Utils.arrayLength(tArgs));
  bool hasVariances = sVariances != null;
  if (JS_GET_FLAG("VARIANCE")) {
    assert(!hasVariances || length == _Utils.arrayLength(sVariances));
  } else {
    assert(!hasVariances);
  }

  for (int i = 0; i < length; i++) {
    Rti sArg = _Utils.asRti(_Utils.arrayAt(sArgs, i));
    Rti tArg = _Utils.asRti(_Utils.arrayAt(tArgs, i));
    if (JS_GET_FLAG("VARIANCE")) {
      int sVariance = hasVariances
          ? _Utils.asInt(_Utils.arrayAt(sVariances, i))
          : Variance.legacyCovariant;
      switch (sVariance) {
        case Variance.legacyCovariant:
        case Variance.covariant:
          if (!_isSubtype(universe, sArg, sEnv, tArg, tEnv)) {
            return false;
          }
          break;
        case Variance.contravariant:
          if (!_isSubtype(universe, tArg, tEnv, sArg, sEnv)) {
            return false;
          }
          break;
        case Variance.invariant:
          if (!_isSubtype(universe, sArg, sEnv, tArg, tEnv) ||
              !_isSubtype(universe, tArg, tEnv, sArg, sEnv)) {
            return false;
          }
          break;
        default:
          throw StateError(
              "Unknown variance given for subtype check: $sVariance");
      }
    } else {
      if (!_isSubtype(universe, sArg, sEnv, tArg, tEnv)) {
        return false;
      }
    }
  }
  return true;
}

bool isNullable(Rti t) {
  int kind = Rti._getKind(t);
  return isNullType(t) ||
      isStrongTopType(t) ||
      kind == Rti.kindQuestion ||
      kind == Rti.kindStar && isNullable(Rti._getStarArgument(t)) ||
      kind == Rti.kindFutureOr && isNullable(Rti._getFutureOrArgument(t));
}

@pragma('dart2js:parameter:trust')
bool isTopType(Rti t) =>
    isStrongTopType(t) ||
    isLegacyObjectType(t) ||
    JS_GET_FLAG('LEGACY') && isObjectType(t);

bool isStrongTopType(Rti t) {
  int kind = Rti._getKind(t);
  return kind == Rti.kindDynamic ||
      kind == Rti.kindVoid ||
      kind == Rti.kindAny ||
      kind == Rti.kindErased ||
      isNullableObjectType(t);
}

bool isBottomType(Rti t) =>
    Rti._getKind(t) == Rti.kindNever || JS_GET_FLAG('LEGACY') && isNullType(t);

bool isObjectType(Rti t) => _Utils.isIdentical(t, TYPE_REF<Object>());
bool isLegacyObjectType(Rti t) =>
    _Utils.isIdentical(t, LEGACY_TYPE_REF<Object>());
bool isNullableObjectType(Rti t) => _Utils.isIdentical(t, TYPE_REF<Object?>());
bool isNullType(Rti t) =>
    _Utils.isIdentical(t, TYPE_REF<Null>()) ||
    _Utils.isIdentical(t, TYPE_REF<JSNull>());
bool isFunctionType(Rti t) => _Utils.isIdentical(t, TYPE_REF<Function>());
bool isJsFunctionType(Rti t) =>
    _Utils.isIdentical(t, TYPE_REF<JavaScriptFunction>());

class _Utils {
  static bool asBool(Object? o) => JS('bool', '#', o);
  static double asDouble(Object? o) => JS('double', '#', o);
  static int asInt(Object? o) => JS('int', '#', o);
  static num asNum(Object? o) => JS('num', '#', o);
  static String asString(Object? o) => JS('String', '#', o);
  static Rti asRti(Object? s) => JS('Rti', '#', s);
  static Rti? asRtiOrNull(Object? s) => JS('Rti|Null', '#', s);

  static bool isString(Object? o) => JS('bool', 'typeof # == "string"', o);
  static bool isNum(Object? o) => JS('bool', 'typeof # == "number"', o);

  static bool instanceOf(Object? o, Object? constructor) =>
      JS('bool', '# instanceof #', o, constructor);

  static bool isIdentical(Object? s, Object? t) => JS('bool', '# === #', s, t);
  static bool isNotIdentical(Object? s, Object? t) =>
      JS('bool', '# !== #', s, t);

  static bool isMultipleOf(int n, int d) => JS('bool', '# % # === 0', n, d);

  static JSArray objectKeys(Object? o) =>
      JS('returns:JSArray;new:true;', 'Object.keys(#)', o);

  static void objectAssign(Object? o, Object? other) {
    // TODO(fishythefish): Use `Object.assign()` when IE11 is deprecated.
    var keys = objectKeys(other);
    int length = arrayLength(keys);
    for (int i = 0; i < length; i++) {
      String key = asString(arrayAt(keys, i));
      JS('', '#[#] = #[#]', o, key, other, key);
    }
  }

  static Object? newArrayOrEmpty(int length) => length > 0
      ? JS('', 'new Array(#)', length)
      : _Universe.sharedEmptyArray(_theUniverse());

  static bool isArray(Object? o) => JS('bool', 'Array.isArray(#)', o);

  static int arrayLength(Object? array) => JS('int', '#.length', array);

  static Object? arrayAt(Object? array, int i) => JS('', '#[#]', array, i);

  static void arraySetAt(Object? array, int i, Object? value) {
    JS('', '#[#] = #', array, i, value);
  }

  static JSArray arrayShallowCopy(Object? array) =>
      JS('JSArray', '#.slice()', array);

  static JSArray arraySplice(Object? array, int position) =>
      JS('JSArray', '#.splice(#)', array, position);

  static JSArray arrayConcat(Object? a1, Object? a2) =>
      JS('JSArray', '#.concat(#)', a1, a2);

  static String substring(String s, int start, int end) =>
      JS('String', '#.substring(#, #)', s, start, end);

  static bool stringLessThan(String s1, String s2) =>
      JS('bool', '# < #', s1, s2);

  static Object? mapGet(Object? cache, Object? key) =>
      JS('', '#.get(#)', cache, key);

  static void mapSet(Object? cache, Object? key, Object? value) {
    JS('', '#.set(#, #)', cache, key, value);
  }
}

// -------- Entry points for testing -------------------------------------------

String testingCanonicalRecipe(Rti rti) {
  return Rti._getCanonicalRecipe(rti);
}

String testingRtiToString(Rti rti) {
  return _rtiToString(rti, null);
}

String testingRtiToDebugString(Rti rti) {
  return _rtiToDebugString(rti);
}

Object testingCreateUniverse() {
  return _Universe.create();
}

void testingAddRules(Object? universe, Object? rules) {
  _Universe.addRules(universe, rules);
}

void testingAddTypeParameterVariances(Object? universe, Object? variances) {
  _Universe.addTypeParameterVariances(universe, variances);
}

bool testingIsSubtype(Object? universe, Rti rti1, Rti rti2) {
  return isSubtype(universe, rti1, rti2);
}

Rti testingUniverseEval(Object? universe, String recipe) {
  return _Universe.eval(universe, recipe, true);
}

void testingUniverseEvalOverride(Object? universe, String recipe, Rti rti) {
  var cache = _Universe.evalCache(universe);
  _Utils.mapSet(cache, recipe, rti);
}

Rti testingEnvironmentEval(Object? universe, Rti environment, String recipe) {
  return _Universe.evalInEnvironment(universe, environment, recipe);
}

Rti testingEnvironmentBind(Object? universe, Rti environment, Rti arguments) {
  return _Universe.bind(universe, environment, arguments);
}
