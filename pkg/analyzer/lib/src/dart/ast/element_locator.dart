// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/ast/extensions.dart';

/// An object used to locate the [Element] associated with a given [AstNode].
class ElementLocator {
  /// Return the element associated with the given [node], or `null` if there
  /// is no element associated with the node.
  static Element? locate(AstNode? node) {
    if (node == null) return null;

    var mapper = _ElementMapper();
    return node.accept(mapper);
  }
}

/// Visitor that maps nodes to elements.
class _ElementMapper extends GeneralizingAstVisitor<Element> {
  @override
  Element? visitAnnotation(Annotation node) {
    return node.element;
  }

  @override
  Element? visitAssignmentExpression(AssignmentExpression node) {
    return node.staticElement;
  }

  @override
  Element? visitBinaryExpression(BinaryExpression node) {
    return node.staticElement;
  }

  @override
  Element? visitClassDeclaration(ClassDeclaration node) {
    return node.declaredElement2;
  }

  @override
  Element? visitClassTypeAlias(ClassTypeAlias node) {
    return node.declaredElement2;
  }

  @override
  Element? visitCompilationUnit(CompilationUnit node) {
    return node.declaredElement;
  }

  @override
  Element? visitConstructorDeclaration(ConstructorDeclaration node) {
    return node.declaredElement2;
  }

  @override
  Element? visitConstructorSelector(ConstructorSelector node) {
    var parent = node.parent;
    if (parent is EnumConstantArguments) {
      var parent2 = parent.parent;
      if (parent2 is EnumConstantDeclaration) {
        return parent2.constructorElement;
      }
    }
    return null;
  }

  @override
  Element? visitDeclaredIdentifier(DeclaredIdentifier node) {
    return node.declaredElement2;
  }

  @override
  Element? visitEnumDeclaration(EnumDeclaration node) {
    return node.declaredElement2;
  }

  @override
  Element? visitExportDirective(ExportDirective node) {
    return node.element2;
  }

  @override
  Element? visitExtensionDeclaration(ExtensionDeclaration node) {
    return node.declaredElement2;
  }

  @override
  Element? visitFormalParameter(FormalParameter node) {
    return node.declaredElement;
  }

  @override
  Element? visitFunctionDeclaration(FunctionDeclaration node) {
    return node.declaredElement2;
  }

  @override
  Element? visitFunctionTypeAlias(FunctionTypeAlias node) {
    return node.declaredElement2;
  }

  @override
  Element? visitGenericTypeAlias(GenericTypeAlias node) {
    return node.declaredElement2;
  }

  @override
  Element? visitIdentifier(Identifier node) {
    var parent = node.parent;
    if (parent is Annotation) {
      // Type name in Annotation
      if (identical(parent.name, node) && parent.constructorName == null) {
        return parent.element;
      }
    } else if (parent is ConstructorDeclaration) {
      // Extra work to map Constructor Declarations to their associated
      // Constructor Elements
      var returnType = parent.returnType;
      if (identical(returnType, node)) {
        var name = parent.name2;
        if (name != null) {
          return parent.declaredElement2;
        }
        var element = node.staticElement;
        if (element is InterfaceElement) {
          return element.unnamedConstructor;
        }
      } else if (parent.name2 == node.endToken) {
        return parent.declaredElement2;
      }
    } else if (parent is LibraryIdentifier) {
      var grandParent = parent.parent;
      if (grandParent is PartOfDirective) {
        var element = grandParent.element2;
        if (element is LibraryElement) {
          return element.definingCompilationUnit;
        }
      } else if (grandParent is LibraryDirective) {
        return grandParent.element2;
      }
    }
    return node.writeOrReadElement;
  }

  @override
  Element? visitImportDirective(ImportDirective node) {
    return node.element2;
  }

  @override
  Element? visitIndexExpression(IndexExpression node) {
    return node.staticElement;
  }

  @override
  Element? visitInstanceCreationExpression(InstanceCreationExpression node) {
    return node.constructorName.staticElement;
  }

  @override
  Element? visitLibraryDirective(LibraryDirective node) {
    return node.element2;
  }

  @override
  Element? visitMethodDeclaration(MethodDeclaration node) {
    return node.declaredElement2;
  }

  @override
  Element? visitMethodInvocation(MethodInvocation node) {
    return node.methodName.staticElement;
  }

  @override
  Element? visitMixinDeclaration(MixinDeclaration node) {
    return node.declaredElement2;
  }

  @override
  Element? visitPartOfDirective(PartOfDirective node) {
    return node.element2;
  }

  @override
  Element? visitPostfixExpression(PostfixExpression node) {
    return node.staticElement;
  }

  @override
  Element? visitPrefixedIdentifier(PrefixedIdentifier node) {
    return node.staticElement;
  }

  @override
  Element? visitPrefixExpression(PrefixExpression node) {
    return node.staticElement;
  }

  @override
  Element? visitStringLiteral(StringLiteral node) {
    final parent = node.parent;
    if (parent is ExportDirective) {
      return parent.element2?.exportedLibrary;
    } else if (parent is ImportDirective) {
      return parent.element2?.importedLibrary;
    } else if (parent is PartDirective) {
      final elementUri = parent.element2?.uri;
      if (elementUri is DirectiveUriWithUnit) {
        return elementUri.unit;
      }
    }
    return null;
  }

  @override
  Element? visitTypeParameter(TypeParameter node) {
    return node.declaredElement2;
  }

  @override
  Element? visitVariableDeclaration(VariableDeclaration node) {
    return node.declaredElement2;
  }
}
