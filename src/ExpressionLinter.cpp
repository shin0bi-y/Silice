/*

    Silice FPGA language and compiler
    (c) Sylvain Lefebvre - @sylefeb

This work and all associated files are under the

     GNU AFFERO GENERAL PUBLIC LICENSE
        Version 3, 19 November 2007

With the additional clause that the copyright notice
above, identitfying the author and original copyright
holder must remain included in all distributions.

(header_1_0)
*/
// -------------------------------------------------
//                                ... hardcoding ...
// -------------------------------------------------

#include "ExpressionLinter.h"
#include "LuaPreProcessor.h"

// -------------------------------------------------

using namespace Silice;

// -------------------------------------------------

antlr4::TokenStream *ExpressionLinter::s_TokenStream     = nullptr;
LuaPreProcessor     *ExpressionLinter::s_LuaPreProcessor = nullptr;

// -------------------------------------------------

void ExpressionLinter::lint(
  siliceParser::Expression_0Context              *expr,
  const Algorithm::t_combinational_block_context *bctx) const
{
  t_type_nfo nfo;
  typeNfo(expr,bctx,nfo);
}

// -------------------------------------------------

void ExpressionLinter::lintAssignment(
  siliceParser::AccessContext                    *access,
  antlr4::tree::TerminalNode                     *identifier,
  siliceParser::Expression_0Context              *expr,
  const Algorithm::t_combinational_block_context *bctx,
  bool                                            wire_definition) const
{
  t_type_nfo lvalue_nfo;
  if (access != nullptr) {
    typeNfo(access, bctx, lvalue_nfo);
  } else {
    sl_assert(identifier != nullptr);
    lvalue_nfo = m_Host->determineIdentifierTypeAndWidth(bctx, identifier, identifier->getSourceInterval(), (int)identifier->getSymbol()->getLine());
  }
  t_type_nfo rvalue_nfo;
  typeNfo(expr, bctx, rvalue_nfo);
  // check
  if (lvalue_nfo.base_type == Parameterized || rvalue_nfo.base_type == Parameterized) {
    //  warn(Standard, expr->getSourceInterval(), -1, "skipping check (parameterized variable : not yet implemented)");
  } else {
    if (!wire_definition) {
      // check not assigning a wire
      std::string vio;
      if (access != nullptr) {
        vio = m_Host->determineAccessedVar(access, bctx);
      } else {
        vio = m_Host->translateVIOName(identifier->getText(), bctx);
      }
      if (m_Host->m_WireAssignmentNames.count(vio) != 0) {
        m_Host->reportError(access != nullptr ? access->getSourceInterval() : identifier->getSourceInterval(), -1,
          "cannot assign to an expression tracker (read only)");
      }
    }
    // warnings
    if (lvalue_nfo.base_type != rvalue_nfo.base_type) {
      if (rvalue_nfo.base_type == Int) {
         warn(Standard, expr->getSourceInterval(), -1, "assigning signed expression to unsigned lvalue");
      }
    }
    if (lvalue_nfo.width < rvalue_nfo.width) {
      if (m_WarnAssignWidth) {
         warn(Standard, expr->getSourceInterval(), -1, "assigning %d bits wide expression to %d bits wide lvalue", rvalue_nfo.width, lvalue_nfo.width);
      }
    }
  }
}

// -------------------------------------------------

void ExpressionLinter::lintWireAssignment(const Algorithm::t_instr_nfo &wire_assign) const
{
  auto alwasg = dynamic_cast<siliceParser::AlwaysAssignedContext *>(wire_assign.instr);
  sl_assert(alwasg != nullptr);
  sl_assert(alwasg->IDENTIFIER() != nullptr);
  lintAssignment(nullptr, alwasg->IDENTIFIER(), alwasg->expression_0(), &wire_assign.block->context, true);
  // check for deprecated symbols
  if (alwasg->ALWSASSIGN() != nullptr) {
     warn(Deprecation, alwasg->getSourceInterval(), -1, "use of deprecated syntax :=, please use <: instead.");
  }
  if (alwasg->ALWSASSIGNDBL() != nullptr) {
     warn(Deprecation, alwasg->getSourceInterval(), -1, "use of deprecated syntax ::=, please use <:: instead.");
  }
}

// -------------------------------------------------

void ExpressionLinter::lintInputParameter(
  std::string                                     name,
  const t_type_nfo                               &param,
  const Algorithm::t_call_param                  &inp,
  const Algorithm::t_combinational_block_context *bctx) const
{
  t_type_nfo rvalue_nfo;
  antlr4::tree::ParseTree *exp = nullptr;
  if (std::holds_alternative<std::string>(inp.what)) {
    typeNfo(std::get<std::string>(inp.what), bctx, rvalue_nfo);
  } else {
    typeNfo(inp.expression, bctx, rvalue_nfo);
  }
  // check
  if (param.base_type != rvalue_nfo.base_type) {
    if (rvalue_nfo.base_type == Int) {
       warn(Standard, inp.expression->getSourceInterval(), -1, "parameter '%s': assigning signed expression to unsigned lvalue", name.c_str());
    }
  }
  if (param.width < rvalue_nfo.width) {
     warn(Standard, inp.expression->getSourceInterval(), -1, "parameter '%s': assigning %d bits wide expression to %d bits wide lvalue", name.c_str(), rvalue_nfo.width, param.width);
  }
}

// -------------------------------------------------

void ExpressionLinter::lintReadback(
  std::string                                     name,
  const Algorithm::t_call_param                  &outp,
  const t_type_nfo                               &rvalue_nfo,
  const Algorithm::t_combinational_block_context *bctx) const
{
  t_type_nfo lvalue_nfo;
  if (std::holds_alternative<siliceParser::AccessContext*>(outp.what)) {
    typeNfo(std::get<siliceParser::AccessContext *>(outp.what), bctx, lvalue_nfo);
  } else if (std::holds_alternative<std::string>(outp.what)) {
    lvalue_nfo = std::get<0>(m_Host->determineVIOTypeWidthAndTableSize(bctx, std::get<std::string>(outp.what), outp.expression->getSourceInterval(), -1));
  }
  // check
  if (lvalue_nfo.base_type != rvalue_nfo.base_type) {
    if (rvalue_nfo.base_type == Int) {
       warn(Standard, outp.expression->getSourceInterval(), -1, "output '%s': assigning signed expression to unsigned lvalue", name.c_str());
    }
  }
  if (lvalue_nfo.width < rvalue_nfo.width) {
     warn(Standard, outp.expression->getSourceInterval(), -1, "output '%s': assigning %d bits wide expression to %d bits wide lvalue", name.c_str(), rvalue_nfo.width, lvalue_nfo.width);
  }
}

// -------------------------------------------------

void ExpressionLinter::lintBinding(
  std::string                                     msg,
  Algorithm::e_BindingDir                         dir,
  int                                             line,
  const t_type_nfo                               &left,
  const t_type_nfo                               &right
) const
{
  // check
  if (left.base_type == Parameterized || right.base_type == Parameterized) {
    return; // skip if parameterized
  }
  if (left.base_type != right.base_type) {
     warn(Standard, antlr4::misc::Interval::INVALID, line, "%s, bindings have inconsistent signedness", msg.c_str());
  }
  if (left.width != right.width) {
     warn(Standard, antlr4::misc::Interval::INVALID, line, "%s, bindings have inconsistent bit-widths", msg.c_str());
  }
}

// -------------------------------------------------

template <int C>
antlr4::tree::ParseTree *child(antlr4::tree::ParseTree *expr)
{
  sl_assert(expr->children.size() > C);
  return expr->children[C];
}

// -------------------------------------------------

void ExpressionLinter::warn(e_WarningType type, antlr4::misc::Interval interval, int line, const char *msg, ...) const
{
  const int messageBufferSize = 4096;
  char message[messageBufferSize];

  va_list args;
  va_start(args, msg);
  vsprintf_s(message, messageBufferSize, msg, args);
  va_end(args);

  switch (type) {
  case Standard:    std::cerr << Console::yellow << "[warning]    " << Console::gray; break;
  case Deprecation: std::cerr << Console::cyan   << "[deprecated] " << Console::gray; break;
  }
  if (line > -1) {
  } else if (s_TokenStream != nullptr && !(interval == antlr4::misc::Interval::INVALID)) {
    antlr4::Token *tk = s_TokenStream->get(interval.a);
    line = (int)tk->getLine();
  }
  if (s_LuaPreProcessor != nullptr) {
    auto fl = s_LuaPreProcessor->lineAfterToFileAndLineBefore(line);
    std::cerr << "(" << Console::white << fl.first << Console::gray << ", line " << sprint("%4d",fl.second) << ") ";
  } else {
    std::cerr << "(" << line << ") ";
  }
  std::cerr << "\n             " << message;
  std::cerr << "\n";
}

// -------------------------------------------------

void ExpressionLinter::checkConcatenation(
  antlr4::tree::ParseTree       *expr,
  const std::vector<t_type_nfo>& tns) const
{
  t_type_nfo t0 = tns.front();
  ForIndex(t, tns.size()) {
    if (tns[t].base_type != t0.base_type) {
       warn(Standard, expr->getSourceInterval(), -1, "signedness of expressions differs in concatenation");
    }
    if (tns[t].width == -1) {
      m_Host->reportError(expr->getSourceInterval(), -1, "concatenation contains expression of unkown bit-width");
    }
  }
}

// -------------------------------------------------

void ExpressionLinter::checkTernary(
  antlr4::tree::ParseTree *expr,
  const t_type_nfo& nfo_a,
  const t_type_nfo& nfo_b
) const {
  if (nfo_a.width != nfo_b.width) {
     warn(Standard, expr->getSourceInterval(), -1, "width of expressions differ in ternary return values");
  }
  if (nfo_a.base_type != nfo_b.base_type) {
     warn(Standard, expr->getSourceInterval(), -1, "signedness of expressions differ in ternary return values");
  }
}

// -------------------------------------------------

static e_Type base_type_of(const t_type_nfo& nfo_a, const t_type_nfo& nfo_b)
{
  if (nfo_a.base_type == UInt || nfo_b.base_type == UInt) {
    return UInt;
  } else {
    return Int;
  }
}

// -------------------------------------------------

void ExpressionLinter::checkAndApplyOperator(
  antlr4::tree::ParseTree *expr,
  std::string       op,
  const t_type_nfo& nfo_a,
  const t_type_nfo& nfo_b,
  t_type_nfo&      _nfo
) const {
  if (op == "+") {
    _nfo.base_type = base_type_of(nfo_a, nfo_b);
    _nfo.width     = max(nfo_a.width, nfo_b.width) + 1;
  } else if (op == "-") {
    _nfo.base_type = base_type_of(nfo_a, nfo_b);
    _nfo.width     = max(nfo_a.width, nfo_b.width) + 1;
  } else if (op == "*") {
    _nfo.base_type = base_type_of(nfo_a, nfo_b);
    _nfo.width     = nfo_a.width + nfo_b.width;
  } else if (op == ">>") {
    if (nfo_a.base_type == Int) {
       warn(Standard, expr->getSourceInterval(), -1, "unsigned shift used on signed value");
    }
    _nfo.base_type = UInt; // force unsigned
    _nfo.width     = nfo_a.width;
  } else if (op == "<<") {
    if (nfo_a.base_type == Int) {
       warn(Standard, expr->getSourceInterval(), -1, "unsigned shift used on signed value");
    }
    _nfo.base_type = UInt; // force unsigned
    _nfo.width     = nfo_a.width;
  } else if (
       op == "==" || op == "===" || op == "!=" || op == "!=="
    || op == "<"  || op == ">"   || op == "<=" || op == ">=") {
    if (nfo_a.base_type != nfo_b.base_type) {
       warn(Standard, expr->getSourceInterval(), -1, "mixed signedness in comparison");
    }
    _nfo.base_type = UInt;
    _nfo.width     = 1;
  } else {
    _nfo.base_type = base_type_of(nfo_a, nfo_b);
    _nfo.width = max(nfo_a.width, nfo_b.width);
  }
}

// -------------------------------------------------

void ExpressionLinter::checkAndApplyUnaryOperator(
  antlr4::tree::ParseTree *expr,
  std::string op,
  const t_type_nfo& nfo_u,
  t_type_nfo& _nfo
) const {
  if (op == "-") {
    _nfo.base_type = nfo_u.base_type;
    _nfo.width     = nfo_u.width;
  } else if (op == "~") {
    _nfo.base_type = nfo_u.base_type;
    _nfo.width     = nfo_u.width;
  } else {
    // all other result in a single bit
    _nfo.base_type = UInt;
    _nfo.width = 1;
  }
}

// -------------------------------------------------

void ExpressionLinter::typeNfo(
  antlr4::tree::ParseTree                        *expr,
  const Algorithm::t_combinational_block_context *bctx,
  t_type_nfo& _nfo) const
{
  // NOTE TODO: const collapsing, so we could use const values in width and operators prediction
  auto atom   = dynamic_cast<siliceParser::AtomContext*>(expr);
  auto term   = dynamic_cast<antlr4::tree::TerminalNode*>(expr);
  auto unary  = dynamic_cast<siliceParser::UnaryExpressionContext*>(expr);
  auto cexpr  = dynamic_cast<siliceParser::ConcatexprContext*>(expr);
  auto concat = dynamic_cast<siliceParser::ConcatenationContext*>(expr);
  auto access = dynamic_cast<siliceParser::AccessContext*>(expr);
  auto expr0  = dynamic_cast<siliceParser::Expression_0Context*>(expr);
  auto expr1  = dynamic_cast<siliceParser::Expression_1Context*>(expr);
  auto expr2  = dynamic_cast<siliceParser::Expression_2Context*>(expr);
  auto expr3  = dynamic_cast<siliceParser::Expression_3Context*>(expr);
  auto expr4  = dynamic_cast<siliceParser::Expression_4Context*>(expr);
  auto expr5  = dynamic_cast<siliceParser::Expression_5Context*>(expr);
  auto expr6  = dynamic_cast<siliceParser::Expression_6Context*>(expr);
  auto expr7  = dynamic_cast<siliceParser::Expression_7Context*>(expr);
  auto expr8  = dynamic_cast<siliceParser::Expression_8Context*>(expr);
  auto expr9  = dynamic_cast<siliceParser::Expression_9Context*>(expr);
  auto expr10 = dynamic_cast<siliceParser::Expression_10Context*>(expr);
  if (term) {
    if (term->getSymbol()->getType() == siliceParser::CONSTANT) {
      constantTypeInfo(term->getText(), _nfo);
    } else if (term->getSymbol()->getType() == siliceParser::NUMBER) {
      _nfo.base_type = UInt;
      _nfo.width     = -1; // undetermined (NOTE: verilog default to 32 bits ...)
    } else if (term->getSymbol()->getType() == siliceParser::IDENTIFIER) {
      _nfo = m_Host->determineIdentifierTypeAndWidth(bctx, term, term->getSourceInterval(), (int)term->getSymbol()->getLine());
      resolveParameterized(term->getText(), bctx, _nfo);
    } else if (term->getSymbol()->getType() == siliceParser::REPEATID) {
      _nfo.base_type = UInt;
      _nfo.width = -1; // unspecified
    } else {
      throw Fatal("internal error [%s, %d]; unrecognized symbol '%s'", __FILE__, __LINE__,term->getText().c_str());
    }
  } else if (access) {
    // ask host to determine access type
    _nfo = m_Host->determineAccessTypeAndWidth(bctx, access, nullptr);
    if (_nfo.base_type == Parameterized) {
      resolveParameterized(m_Host->determineAccessedVar(access, bctx), bctx, _nfo);
    }
  } else if (atom) {
    auto concat_ = dynamic_cast<siliceParser::ConcatenationContext*>(atom->concatenation());
    auto access_ = dynamic_cast<siliceParser::AccessContext*>(atom->access());
    if (atom->TOUNSIGNED() != nullptr) {
      // recurse and force uint
      typeNfo(atom->expression_0(), bctx, _nfo);
      _nfo.base_type = UInt;
    } else if (atom->TOSIGNED() != nullptr) {
      // recurse and force int
      typeNfo(atom->expression_0(), bctx, _nfo);
      _nfo.base_type = Int;
    } else if (atom->WIDTHOF() != nullptr) {
      // force uint 32 bits
      _nfo.width     = -1; // undetermined (NOTE: verilog default to 32 bits ...)
      _nfo.base_type = UInt;
    } else if (access_) {
      // recurse
      typeNfo(access_, bctx, _nfo);
    } else if (concat_) {
      // recurse
      typeNfo(concat_, bctx, _nfo);
    } else if (atom->expression_0()) {
      // recurse on parenthesis
      typeNfo(atom->expression_0(), bctx, _nfo);
    } else if (atom->DONE() != nullptr) {
      _nfo.width = 1;
      _nfo.base_type = UInt;
    } else {
      // recurse on terminal symbol
      typeNfo(child<0>(expr), bctx, _nfo);
    }
  } else if (unary) {
    if (unary->children.size() == 2) {
      // recurse and check
      t_type_nfo nfo_u;
      typeNfo(unary->atom(), bctx, nfo_u);
      checkAndApplyUnaryOperator(expr, child<0>(expr)->getText(), nfo_u, _nfo);
    } else {
      // recurse
      typeNfo(unary->atom(), bctx, _nfo);
    }
  } else if (concat) {
    // recurse and check signedness consitency
    sl_assert(!expr->children.empty());
    std::vector<t_type_nfo> tns;
    for (auto c : concat->concatexpr()) {
      tns.push_back(t_type_nfo());
      typeNfo(c, bctx, tns.back());
    }
    checkConcatenation(expr, tns);
    _nfo.base_type = tns.front().base_type;
    _nfo.width = 0;
    for (auto tn : tns) {
      _nfo.width += tn.width;
    }
  } else if (cexpr) {
    if (cexpr->expression_0()) {
      // recurse
      typeNfo(cexpr->expression_0(), bctx, _nfo);
    } else {
      // recurse on concatenation
      typeNfo(cexpr->concatenation(), bctx, _nfo);
      // get number
      int num    = std::stoi(cexpr->NUMBER()->getText());
      _nfo.width = _nfo.width * num;
    }
  } else if (expr0 || expr1 || expr2 || expr3 || expr4 || expr5 
          || expr6 || expr7 || expr8 || expr9 || expr10) {
    if (expr->children.size() == 1) {
      // recurse
      typeNfo(child<0>(expr), bctx, _nfo);
    } else if (expr->children.size() == 3) {
      // recurse both sides and check
      t_type_nfo nfo_a, nfo_b;
      typeNfo(child<0>(expr), bctx, nfo_a);
      typeNfo(child<2>(expr), bctx, nfo_b);
      checkAndApplyOperator(expr, child<1>(expr)->getText(), nfo_a, nfo_b, _nfo);
    } else {
      sl_assert(expr->children.size() == 5);
      // recurse both sides and check
      t_type_nfo nfo_a, nfo_b, nfo_if;
      typeNfo(child<0>(expr), bctx, nfo_if);
      typeNfo(child<2>(expr), bctx, nfo_a);
      typeNfo(child<4>(expr), bctx, nfo_b);
      checkTernary(expr, nfo_a, nfo_b);
      _nfo.base_type = base_type_of(nfo_a, nfo_b);
      _nfo.width     = max(nfo_a.width, nfo_b.width);
    }
  } else {
    throw Fatal("internal error [%s, %d] '%s'", __FILE__, __LINE__,expr->getText().c_str());
  }
}

// -------------------------------------------------

void ExpressionLinter::resolveParameterized(std::string idnt, const Algorithm::t_combinational_block_context *bctx, t_type_nfo &_nfo) const
{
  if (_nfo.base_type != Parameterized) {
    return;
  }
  // translate
  idnt = m_Host->translateVIOName(idnt, bctx);
  // get definition
  bool found = false;
  Algorithm::t_var_nfo v = m_Host->getVIODefinition(idnt, found);
  if (!found) {
    throw Fatal("internal error [%s, %d] '%s'", __FILE__, __LINE__, idnt.c_str());
  }
  // fill parameter values
  _nfo.base_type = m_Host->varType(v, m_Ictx);
  _nfo.width     = std::atoi(m_Host->varBitWidth(v, m_Ictx).c_str());
  _nfo.same_as   = "";
}

// -------------------------------------------------

void ExpressionLinter::typeNfo(
  std::string                                     idnt,
  const Algorithm::t_combinational_block_context *bctx,
  t_type_nfo& _nfo) const
{
  _nfo = std::get<0>(m_Host->determineVIOTypeWidthAndTableSize(bctx, idnt, antlr4::misc::Interval::INVALID , -1));
  resolveParameterized(idnt, bctx, _nfo);
}

// -------------------------------------------------

antlr4::Token *ExpressionLinter::getToken(antlr4::misc::Interval interval,bool last_else_first)
{
  if (s_TokenStream != nullptr && !(interval == antlr4::misc::Interval::INVALID)) {
    antlr4::Token *tk = s_TokenStream->get(last_else_first ? interval.b : interval.a);
    return tk;
  } else {
    return nullptr;
  }
}

// -------------------------------------------------

std::pair<std::string, int> ExpressionLinter::getTokenSourceFileAndLine(antlr4::Token *tk)
{
  int line = (int)tk->getLine();
  if (s_LuaPreProcessor != nullptr) {
    auto fl = s_LuaPreProcessor->lineAfterToFileAndLineBefore(line);
    return fl;
  } else {
    return std::make_pair("", line);
  }
}

// -------------------------------------------------
