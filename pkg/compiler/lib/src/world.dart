// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.10

library dart2js.world;

import 'closure.dart';
import 'common/elements.dart' show JCommonElements, JElementEnvironment;
import 'deferred_load/output_unit.dart' show OutputUnitData;
import 'elements/entities.dart';
import 'elements/names.dart';
import 'elements/types.dart';
import 'inferrer/abstract_value_domain.dart';
import 'js_backend/annotations.dart';
import 'js_backend/field_analysis.dart' show JFieldAnalysis;
import 'js_backend/backend_usage.dart' show BackendUsage;
import 'js_backend/interceptor_data.dart' show InterceptorData;
import 'js_backend/native_data.dart' show NativeData;
import 'js_backend/no_such_method_registry.dart' show NoSuchMethodData;
import 'js_backend/runtime_types_resolution.dart' show RuntimeTypesNeed;
import 'js_emitter/sorter.dart';
import 'universe/class_hierarchy.dart';
import 'universe/member_usage.dart';
import 'universe/selector.dart' show Selector;

import 'world_interfaces.dart' as interfaces;

export 'world_interfaces.dart' show World, BuiltWorld;

/// The [JClosedWorld] represents the information known about a program when
/// compiling with closed-world semantics.
///
/// Given the entrypoint of an application, we can track what's reachable from
/// it, what functions are called, what classes are allocated, which native
/// JavaScript types are touched, what language features are used, and so on.
/// This precise knowledge about what's live in the program is later used in
/// optimizations and other compiler decisions during code generation.
// TODO(johnniwinther): Maybe this should just be called the JWorld.
abstract class JClosedWorld implements interfaces.JClosedWorld {
  JFieldAnalysis get fieldAnalysis;

  BackendUsage get backendUsage;

  @override
  NativeData get nativeData;

  InterceptorData get interceptorData;

  @override
  JElementEnvironment get elementEnvironment;

  @override
  DartTypes get dartTypes;

  @override
  JCommonElements get commonElements;

  /// Returns the [AbstractValueDomain] used in the global type inference.
  @override
  AbstractValueDomain get abstractValueDomain;

  RuntimeTypesNeed get rtiNeed;

  NoSuchMethodData get noSuchMethodData;

  Iterable<ClassEntity> get liveNativeClasses;

  Iterable<MemberEntity> get processedMembers;

  /// Returns the set of interfaces passed as type arguments to the internal
  /// `extractTypeArguments` function.
  Set<ClassEntity> get extractTypeArgumentsInterfacesNewRti;

  @override
  ClassHierarchy get classHierarchy;

  @override
  AnnotationsData get annotationsData;

  ClosureData get closureDataLookup;

  OutputUnitData get outputUnitData;

  /// The [Sorter] used for sorting elements in the generated code.
  Sorter get sorter;

  /// Returns `true` if [cls] is implemented by an instantiated class.
  bool isImplemented(ClassEntity cls);

  /// Returns the most specific subclass of [cls] (including [cls]) that is
  /// directly instantiated or a superclass of all directly instantiated
  /// subclasses. If [cls] is not instantiated, `null` is returned.
  ClassEntity getLubOfInstantiatedSubclasses(ClassEntity cls);

  /// Returns the most specific subtype of [cls] (including [cls]) that is
  /// directly instantiated or a superclass of all directly instantiated
  /// subtypes. If no subtypes of [cls] are instantiated, `null` is returned.
  ClassEntity getLubOfInstantiatedSubtypes(ClassEntity cls);

  /// Returns an iterable over the common supertypes of the [classes].
  Iterable<ClassEntity> commonSupertypesOf(Iterable<ClassEntity> classes);

  /// Returns an iterable over the live mixin applications that mixin [cls].
  Iterable<ClassEntity> mixinUsesOf(ClassEntity cls);

  /// Returns `true` if [cls] is mixed into a live class.
  @override
  bool isUsedAsMixin(ClassEntity cls);

  /// Returns `true` if any live class that mixes in [cls] implements [type].
  bool hasAnySubclassOfMixinUseThatImplements(
      ClassEntity cls, ClassEntity type);

  /// Returns `true` if any live class that mixes in [mixin] is also a subclass
  /// of [superclass].
  bool hasAnySubclassThatMixes(ClassEntity superclass, ClassEntity mixin);

  /// Returns `true` if [cls] or any superclass mixes in [mixin].
  bool isSubclassOfMixinUseOf(ClassEntity cls, ClassEntity mixin);

  /// Returns `true` if every subtype of [x] is a subclass of [y] or a subclass
  /// of a mixin application of [y].
  bool everySubtypeIsSubclassOfOrMixinUseOf(ClassEntity x, ClassEntity y);

  /// Returns `true` if any subclass of [superclass] implements [type].
  bool hasAnySubclassThatImplements(ClassEntity superclass, ClassEntity type);

  /// Returns `true` if a call of [selector] on [cls] and/or subclasses/subtypes
  /// need noSuchMethod handling.
  ///
  /// If the receiver is guaranteed to have a member that matches what we're
  /// looking for, there's no need to introduce a noSuchMethod handler. It will
  /// never be called.
  ///
  /// As an example, consider this class hierarchy:
  ///
  ///                   A    <-- noSuchMethod
  ///                  / \
  ///                 C   B  <-- foo
  ///
  /// If we know we're calling foo on an object of type B we don't have to worry
  /// about the noSuchMethod method in A because objects of type B implement
  /// foo. On the other hand, if we end up calling foo on something of type C we
  /// have to add a handler for it.
  ///
  /// If the holders of all user-defined noSuchMethod implementations that might
  /// be applicable to the receiver type have a matching member for the current
  /// name and selector, we avoid introducing a noSuchMethod handler.
  ///
  /// As an example, consider this class hierarchy:
  ///
  ///                        A    <-- foo
  ///                       / \
  ///    noSuchMethod -->  B   C  <-- bar
  ///                      |   |
  ///                      C   D  <-- noSuchMethod
  ///
  /// When calling foo on an object of type A, we know that the implementations
  /// of noSuchMethod are in the classes B and D that also (indirectly)
  /// implement foo, so we do not need a handler for it.
  ///
  /// If we're calling bar on an object of type D, we don't need the handler
  /// either because all objects of type D implement bar through inheritance.
  ///
  /// If we're calling bar on an object of type A we do need the handler because
  /// we may have to call B.noSuchMethod since B does not implement bar.
  bool needsNoSuchMethod(ClassEntity cls, Selector selector, ClassQuery query);

  /// Returns whether [element] will be the one used at runtime when being
  /// invoked on an instance of [cls]. [name] is used to ensure library
  /// privacy is taken into account.
  bool hasElementIn(ClassEntity cls, Name name, MemberEntity element);

  /// Returns `true` if the field [element] is known to be effectively final.
  @override
  bool fieldNeverChanges(MemberEntity element);

  /// Returns `true` if [selector] on [receiver] can hit a `call` method on a
  /// subclass of `Closure` using the [abstractValueDomain].
  ///
  /// Every implementation of `Closure` has a 'call' method with its own
  /// signature so it cannot be modelled by a [FunctionEntity]. Also,
  /// call-methods for tear-off are not part of the element model.
  bool includesClosureCallInDomain(Selector selector, AbstractValue receiver,
      AbstractValueDomain abstractValueDomain);

  /// Returns `true` if [selector] on [receiver] can hit a `call` method on a
  /// subclass of `Closure`.
  ///
  /// Every implementation of `Closure` has a 'call' method with its own
  /// signature so it cannot be modelled by a [FunctionEntity]. Also,
  /// call-methods for tear-off are not part of the element model.
  @override
  bool includesClosureCall(Selector selector, AbstractValue receiver);

  /// Returns the mask for the potential receivers of a dynamic call to
  /// [selector] on [receiver].
  ///
  /// This will narrow the constraints of [receiver] to an [AbstractValue] of
  /// the set of classes that actually implement the selected member or
  /// implement the handling 'noSuchMethod' where the selected member is
  /// unimplemented.
  AbstractValue computeReceiverType(Selector selector, AbstractValue receiver);

  /// Returns all the instance members that may be invoked with the [selector]
  /// on the given [receiver] using the [abstractValueDomain]. The returned elements may include noSuchMethod
  /// handlers that are potential targets indirectly through the noSuchMethod
  /// mechanism.
  Iterable<MemberEntity> locateMembersInDomain(Selector selector,
      AbstractValue receiver, AbstractValueDomain abstractValueDomain);

  /// Returns all the instance members that may be invoked with the [selector]
  /// on the given [receiver]. The returned elements may include noSuchMethod
  /// handlers that are potential targets indirectly through the noSuchMethod
  /// mechanism.
  @override
  Iterable<MemberEntity> locateMembers(
      Selector selector, AbstractValue receiver);

  /// Returns the single [MemberEntity] that matches a call to [selector] on the
  /// [receiver]. If multiple targets exist, `null` is returned.
  MemberEntity locateSingleMember(Selector selector, AbstractValue receiver);

  /// Returns the set of read, write, and invocation accesses found on [member]
  /// during the closed world computation.
  MemberAccess getMemberAccess(MemberEntity member);

  /// Registers [interface] as a type argument to `extractTypeArguments`.
  void registerExtractTypeArguments(ClassEntity interface);
}
