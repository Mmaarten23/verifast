#pragma once

#include "stubs_ast.capnp.h"
#include "clang/Basic/FileManager.h"
#include "clang/Basic/SourceManager.h"
#include "clang/AST/ASTContext.h"

namespace vf {

struct LCF {
  unsigned int l;
  unsigned int c;
  unsigned int f;
};

/**
 * Decompose the line, column and file unique identifier from a source location.
 * The result will be placed in the given \p lcf if the given location \p loc is
 * valid and not coming from a 'real' file (not a system file).
 *
 * @param loc source location to decompose.
 * @param SM source manager.
 * @param[out] lcf struct to place the line, column and file uniques identifier
 * in.
 * @return true if the given location \p loc was valid and could be decomposed.
 * @return false if the given location \p was invalid and it was not possible to
 * decompose it.
 */
bool decomposeLocToLCF(clang::SourceLocation loc,
                       const clang::SourceManager &SM, LCF &lcf);

void serializeSourcePos(stubs::Loc::SrcPos::Builder builder, LCF lcf);

void serializeSourceRange(stubs::Loc::Builder builder,
                          clang::SourceRange range,
                          const clang::SourceManager &SM,
                          const clang::LangOptions &langOpts);

void serializeSourceRange(stubs::Loc::Builder builder, clang::SourceRange range, const clang::ASTContext &ASTContext);

const clang::FileEntry *getFileEntry(clang::SourceLocation loc,
                                     const clang::SourceManager &SM);

} // namespace vf