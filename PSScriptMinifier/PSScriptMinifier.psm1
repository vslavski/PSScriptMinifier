#Requires -Version 7
using namespace System.Management.Automation.Language

class MinifyVisitor : AstVisitor2 {
  [System.Text.StringBuilder]$sb

  MinifyVisitor() {
    $this.sb = [System.Text.StringBuilder]::new()
  }

  static [string] GetMinified([ScriptBlockAst]$ast) {
    $visitor = [MinifyVisitor]::new()
    $ast.Visit($visitor)
    return $visitor.sb.ToString().TrimEnd()
  }

  hidden [string] GetPrevChar() {
    return $this.sb.ToString()?[-1]
  }

  hidden [void] Append([string]$text) {
    if ($this.sb.Length -gt 0) {
      if ($this.GetPrevChar() -match '[%*?]|\w' -and $text -match '^@|-?\w+') {
        $this.sb.Append(' ') | Out-Null
      }
    }
    $this.sb.Append($text) | Out-Null
  }

  hidden [void] RemoveTrailingSemi() {
    if($this.GetPrevChar() -eq ';'){$this.sb.Remove($this.sb.Length - 1, 1)}
  }

  hidden [void] AppendSemi() {
    if($this.GetPrevChar() -ne ';'){$this.Append(';')}
  }

  hidden [void] AppendSemiIf([bool]$cond) {
    if($cond){$this.AppendSemi()}
  }

  [AstVisitAction] VisitCommand([CommandAst]$node) {
    switch ($node.InvocationOperator) {
      'Dot' {
        $this.Append('.')
      }
      'Ampersand' {
        $this.Append('&')
      }
    }
    return [AstVisitAction]::Continue
  }

  [AstVisitAction] VisitStatementBlock([StatementBlockAst]$node) {
    $stmts = $node.Statements
    for ($i = 0; $i -lt $stmts.Count; $i++) {
      $stmts[$i].Visit($this)
      $this.AppendSemiIf($i -lt $stmts.Count - 1)
    }
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitFunctionDefinition([FunctionDefinitionAst]$node) {
    $kwd = if ($node.IsFilter) {
      'filter '
    } elseif ($node.IsWorkflow) {
      'workflow '
    } else {
      'function '
    }
    $this.Append($kwd)
    $this.Append($node.Name)
    $params = $node.Parameters
    $n = $params.Count
    if ($n) {
      $this.Append('(')
      for ($i = 0; $i -lt $n; $i++) {
        $params[$i].Visit($this)
        if ($i -lt $n - 1) {
          $this.Append(',')
        }
      }
      $this.RemoveTrailingSemi()
      $this.Append(')')
    }
    $this.Append('{')
    ($node.Body)?.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append('}')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitScriptBlockExpression([ScriptBlockExpressionAst]$node) {
    $this.Append('{')
    ($node.ScriptBlock)?.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append('}')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitScriptBlock([ScriptBlockAst]$node) {
    $node.UsingStatements | % { $_.Visit($this) }
    $node.Attributes | % { $_.Visit($this) }
    ($node.ParamBlock)?.Visit($this)
    ($node.DynamicParamBlock)?.Visit($this)
    ($node.BeginBlock)?.Visit($this)
    ($node.ProcessBlock)?.Visit($this)
    ($node.EndBlock)?.Visit($this)
    ($node.CleanBlock)?.Visit($this)
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitNamedBlock([NamedBlockAst]$node) {
    if (-not $node.Unnamed) {
      $this.Append($node.BlockKind.ToString().ToLower())
      $this.Append('{')
    }
    $stmts = $node.Statements
    $n = $stmts.Count
    if ($n) {
      for ($i = 0; $i -lt $n; $i++) {
        $stmt = $stmts[$i]
        ($stmt)?.Visit($this)
        $this.AppendSemiIf($i -lt $n - 1)
      }
    }
    if (-not $node.Unnamed) {
      $this.RemoveTrailingSemi()
      $this.Append('}')
    }
    $node.Traps | % { ($_)?.Visit($this) }
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitCommandParameter([CommandParameterAst]$node) {
    $this.Append("-$($node.ParameterName)")
    ($node.Argument)?.Visit($this)
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitPipeline([PipelineAst]$node) {
    $elts = $node.PipelineElements
    $n = $elts.Count
    for ($i = 0; $i -lt $n; $i++) {
      $elt = $elts[$i]
      $elt.Visit($this)
      if ($i -lt $n - 1) {
        $this.Append('|')
      }
    }
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitAttributedExpression([AttributedExpressionAst] $node) {
    $attr = $node.Attribute.Extent.Text.Replace("`n", '')
    $this.Append($attr)
    $node.Child.Visit($this)
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitCommandExpression([CommandExpressionAst] $node) {
    ($node.Expression)?.Visit($this)
    foreach ($redir in $node.Redirections) {
      $redir.Visit($this)
    }
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitIfStatement([IfStatementAst]$node) {
    $clauses = $node.Clauses
    $n = $clauses.Count
    for ($i = 0; $i -lt $n; $i++) {
      if ($i -eq 0) {
        $this.Append('if(')
      } else {
        $this.Append('elseif(')
      }
      ($clauses[$i].Item1)?.Visit($this)
      $this.RemoveTrailingSemi()
      $this.Append(')')
      $this.Append('{')
      ($clauses[$i].Item2)?.Visit($this)
      $this.RemoveTrailingSemi()
      $this.Append('}')
    }
    if ($node.ElseClause) {
      $this.Append('else{')
      ($node.ElseClause)?.Visit($this)
      $this.RemoveTrailingSemi()
      $this.Append('}')
    }
    $this.AppendSemi()
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitAssignmentStatement([AssignmentStatementAst]$node) {
    ($node.Left)?.Visit($this)
    $opStart = $node.Left.Extent.EndOffset
    $opLen = $node.Right.Extent.StartOffset - $opStart
    $opRelOffset = $opStart - $node.Extent.StartOffset
    $this.Append($node.Extent.Text.Substring($opRelOffset, $opLen).Trim())
    ($node.Right)?.Visit($this)
    $this.AppendSemi()
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitForStatement([ForStatementAst]$node) {
    if ($node.Label) {
      $this.sb.Append(':{0} ' -f $node.Label)
    }
    $this.Append('for(')
    if ($node.Initializer) {
      ($node.Initializer)?.Visit($this)
      $this.AppendSemi()
    }
    if ($node.Condition) {
      ($node.Condition)?.Visit($this)
      $this.AppendSemi()
    }
    ($node.Iterator)?.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append(')')
    $this.Append('{')
    ($node.Body)?.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append('};')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitForEachStatement([ForEachStatementAst]$node) {
    if ($node.Label) {
      $this.sb.Append(':{0} ' -f $node.Label)
    }
    $this.Append('foreach(')
    ($node.Variable)?.Visit($this)
    $this.Append('in')
    ($node.Condition)?.Visit($this)
    if ($node.ThrottleLimit) {
      $this.Append('-ThrottleLimit')
      ($node.ThrottleLimit)?.Visit($this)
    }
    $this.RemoveTrailingSemi()
    $this.Append('){')
    ($node.Body)?.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append('};')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitDoUntilStatement([DoUntilStatementAst]$node) {
    if ($node.Label) {
      $this.sb.Append(':{0} ' -f $node.Label)
    }
    $this.Append('do{')
    ($node.Body)?.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append('}until(')
    ($node.Condition)?.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append(');')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitDoWhileStatement([DoWhileStatementAst]$node) {
    if ($node.Label) {
      $this.sb.Append(':{0} ' -f $node.Label)
    }
    $this.Append('do{')
    ($node.Body)?.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append('}while(')
    ($node.Condition)?.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append(');')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitSubExpression([SubExpressionAst]$node) {
    $this.Append('$(')
    ($node.SubExpression)?.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append(')')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitTryStatement([TryStatementAst] $node) {
    $this.Append('try{')
    if ($node.Body) {
      $node.Body.Visit($this)
      $this.RemoveTrailingSemi()
    }
    $this.Append('}')
    foreach ($catch in $node.CatchClauses) {
      $catch.Visit($this)
    }
    if ($node.Finally) {
      $this.Append('finally{')
      $node.Finally.Visit($this)
      $this.RemoveTrailingSemi()
      $this.Append('}')
    }
    $this.AppendSemi()
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitCatchClause([CatchClauseAst] $node) {
    $this.Append('catch')
    if ($node.CatchTypes.Count -gt 0) {
      $this.Append(' ')
      for ($i = 0; $i -lt $node.CatchTypes.Count; $i++) {
        $node.CatchTypes[$i].Visit($this)
        if ($i -lt $node.CatchTypes.Count - 1) {
          $this.Append(',')
        }
      }
    }
    $this.Append('{')
    if ($node.Body) {
      $node.Body.Visit($this)
      $this.RemoveTrailingSemi()
    }
    $this.Append('}')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitThrowStatement([ThrowStatementAst]$node) {
    $this.Append('throw ')
    ($node.Pipeline)?.Visit($this)
    ($node.Exception)?.Visit($this)
    $this.AppendSemi()
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitSwitchStatement([SwitchStatementAst]$node) {
    $this.Append('switch(')
    $node.Condition.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append('){')
    $node.Clauses | % {
      $_.Item1.Visit($this)
      $this.Append('{')
      $_.Item2.Visit($this)
      $this.RemoveTrailingSemi()
      $this.Append('}')
    }
    if ($node.DefaultClause) {
      $this.Append('default {')
      ($node.DefaultClause)?.Visit($this)
      $this.RemoveTrailingSemi()
      $this.Append('}')
    }
    $this.Append('};')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitUsingStatement([UsingStatementAst]$node) {
    $this.Append($node.Extent.Text)
    $this.AppendSemi()
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitParamBlock([ParamBlockAst]$node) {
    $node.Attributes | ForEach-Object { $_.Visit($this) }
    $this.Append('param(')
    $params = $node.Parameters
    $n = $params.Count
    for ($i = 0; $i -lt $n; $i++) {
      $params[$i].Visit($this)
      if ($i -lt $n - 1) {
        $this.Append(',')
      }
    }
    $this.Append(');')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitParameter([ParameterAst]$node) {
    $node.Attributes | ForEach-Object { $_.Visit($this) }
    $this.Append($node.Name)
    if ($node.DefaultValue) {
      $this.Append('=')
      $node.DefaultValue.Visit($this)
    }
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitAttribute([AttributeAst]$node) {
    $this.Append('[')
    $allArgs = @()
    $allArgs += $node.PositionalArguments
    $allArgs += $node.NamedArguments
    $this.Append("$($node.TypeName)($($allArgs -join ','))")
    $this.Append(']')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitTrap([TrapStatementAst]$node) {
    $this.Append('trap ')
    ($node.Filter)?.Visit($this)
    $node.Body.Visit($this)
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitParenExpression([ParenExpressionAst]$node) {
    $this.Append('(')
    ($node.Pipeline)?.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append(')')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitMemberExpression([MemberExpressionAst] $node) {
    ($node.Expression)?.Visit($this)
    if ($node.NullConditional) {$this.Append('?')}
    $this.Append($(if($node.Static){'::'}else{'.'}))
    $this.Append($node.Member)
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitInvokeMemberExpression([InvokeMemberExpressionAst] $node) {
    ($node.Expression)?.Visit($this)
    if ($node.NullConditional) {$this.Append('?')}
    $this.Append($(if($node.Static){'::'}else{'.'}))
    $this.Append($node.Member)
    if ($node.GenericTypeArguments.Count -gt 0) {
      $this.Append('[')
      for ($i = 0; $i -lt $node.GenericTypeArguments.Count; $i++) {
        $node.GenericTypeArguments[$i].Visit($this)
        if ($i -lt $node.GenericTypeArguments.Count - 1) {
          $this.Append(',')
        }
      }
      $this.Append(']')
    }
    $this.Append('(')
    for ($i = 0; $i -lt $node.Arguments.Count; $i++) {
      $arg = $node.Arguments[$i]
      $arg.Visit($this)
      if ($i -lt $node.Arguments.Count - 1) {
        $this.Append(',')
      }
    }
    $this.Append(')')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitWhileStatement([WhileStatementAst]$node) {
    if ($node.Label) {
      $this.Append(':{0} ' -f $node.Label)
    }
    $this.Append('while(')
    $node.Condition.Visit($this)
    $this.RemoveTrailingSemi()
    $this.Append('){')
    foreach ($s in $node.Body.Statements) {
      $s.Visit($this)
      $this.AppendSemi()
    }
    $this.Append('}')
    return [AstVisitAction]::SkipChildren
  }


  [AstVisitAction] VisitHashtable([HashtableAst]$node) {
    $this.Append('@{')
    $n = $node.KeyValuePairs.Count
    for ($i = 0; $i -lt $n; $i++) {
      $key = $node.KeyValuePairs[$i].Item1
      $value = $node.KeyValuePairs[$i].Item2
      $key.Visit($this)
      $this.Append('=')
      $value.Visit($this)
      $this.AppendSemiIf($i -lt $n - 1)
    }
    $this.Append('}')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitArrayExpression([ArrayExpressionAst]$node) {
    $this.Append('@(')
    $node.SubExpression.Statements | % { $_.Visit($this) }
    $this.Append(')')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitArrayLiteral([ArrayLiteralAst]$node) {
    $n = $node.Elements.Count
    for ($i = 0; $i -lt $n; $i++) {
      $node.Elements[$i].Visit($this)
      if ($i -lt $n - 1) {
        $this.Append(',')
      }
    }
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitVariableExpression([VariableExpressionAst]$node) {
    $path = $node.VariablePath
    $this.Append("$(if($node.Splatted){'@'}else{'$'})$path")
    return [AstVisitAction]::Continue
  }

  [AstVisitAction] VisitBinaryExpression([BinaryExpressionAst]$node) {
    $opSpan = @($node.Left.Extent.EndOffset - $node.Extent.StartOffset)
    $opSpan += $node.Right.Extent.StartOffset - $node.Left.Extent.EndOffset
    $opToken = $node.Extent.Text.Substring($opSpan[0], $opSpan[-1])
    $node.Left.Visit($this)
    $this.Append($opToken.Trim())
    $node.Right.Visit($this)
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitUnaryExpression([UnaryExpressionAst]$node) {
    $nodeExt = $node.Extent
    $childExt = $node.Child.Extent
    $isPostfix = $node.TokenKind.ToString().StartsWith('Postfix')
    if ($isPostfix) {
      $opSpan = @($childExt.EndOffset - $nodeExt.StartOffset)
      $opSpan += ($nodeExt.Text.Length - $opSpan[0])
      $opToken = $nodeExt.Text.Substring($opSpan[0], $opSpan[-1])
      $node.Child.Visit($this)
      $this.Append($opToken.Trim())
    } else {
      $opToken = $nodeExt.Text.Substring(0, $childExt.StartOffset - $nodeExt.StartOffset)
      $this.Append($opToken.Trim())
      $node.Child.Visit($this)
    }
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitTypeConstraint([TypeConstraintAst]$node) {
    $this.Append("[$($node.TypeName)]")
    return [AstVisitAction]::Continue
  }

  [AstVisitAction] VisitTypeExpression([TypeExpressionAst]$node) {
    $this.Append("[$($node.TypeName)]")
    return [AstVisitAction]::Continue
  }

  [AstVisitAction] VisitIndexExpression([IndexExpressionAst]$node) {
    $this.sb.Append($node.Target.ToString().Trim())
    if ($node.NullConditional) {
      $this.sb.Append('?')
    }
    $this.sb.Append('[' + $node.Index + ']')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitTypeDefinition([TypeDefinitionAst]$node) {
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($node.Extent.Text)
    $enc = [Convert]::ToBase64String($bytes)
    $b64DecodeExpr = "[System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String(`"$enc`"))"
    $this.sb.Append("iex ($b64DecodeExpr)")
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitFunctionMember([FunctionMemberAst]$node) {
    if ($node.IsHidden) {
      $this.Append('hidden ')
    }
    if ($node.IsStatic) {
      $this.Append('static ')
    }
    if ($node.IsConstructor) {
      $this.Append($node.Parent.Name)
    } else {
      if ($node.ReturnType) {
        $node.ReturnType.Visit($this)
        $this.sb.Append(' ')
      }
      $this.Append($node.Name)
    }
    $n = $node.Parameters.Count
    $this.Append('(')
    for ($i = 0; $i -lt $n; $i++) {
      $param = $node.Parameters[$i]
      $param.Visit($this)
      if ($i -lt $n - 1) {
        $this.Append(',')
      }
    }
    $this.Append('){')
    ($node.Body)?.Visit($this)
    $this.Append('};')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitPropertyMember([PropertyMemberAst]$node) {
    $node.Attributes | % { $_.Visit($this) }
    if ($node.IsHidden) {
      $this.Append('hidden ')
    }
    if ($node.IsStatic) {
      $this.Append('static ')
    }
    ($node.PropertyType)?.Visit($this)
    $this.Append("`$$($node.Name)")
    if ($node.InitialValue) {
      $this.Append('=')
      $node.InitialValue.Visit($this)
    }
    $this.Append("`n")
    return [AstVisitAction]::SkipChildren
  }


  [AstVisitAction] VisitReturnStatement([ReturnStatementAst]$node) {
    $this.Append('return')
    if ($node.Pipeline) {
      $this.sb.Append(' ')
      $node.Pipeline.Visit($this)
    }
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitContinueStatement([ContinueStatementAst]$node) {
    $this.Append('continue')
    if ($node.Label) {
      $this.Append(' ' + $node.Label)
    }
    $this.Append(';')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitBreakStatement([BreakStatementAst]$node) {
    $this.Append('break')
    if ($node.Label) {
      $this.Append(' ' + $node.Label)
    }
    $this.Append(';')
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] VisitExitStatement([ExitStatementAst]$node) {
    $this.Append('exit ')
    ($node.Pipeline)?.Visit($this)
    return [AstVisitAction]::SkipChildren
  }

  [AstVisitAction] DefaultVisit([Ast]$node) {
    Write-Debug "[DEFAULT-VISIT][TYPE]: $($node.GetType().FullName)"
    Write-Debug "[DEFAULT-VISIT][VALUE]: $node"
    $this.Append($node.Extent.Text)
    return [AstVisitAction]::SkipChildren
  }
}

function Remove-ScriptTrivia {
  param([Parameter(Position = 0, ValueFromPipeline)][string]$text)
  Write-Debug @"
[SCRIPT-DEFINITION]
``````
$text
``````
"@
  $toks = $errs = $null
  [void][Parser]::ParseInput($text, [ref]$toks, [ref]$errs)
  if ($errs) {
    $errs | % { Write-Error ($_) }
    break
  }
  $cleanSb = [System.Text.StringBuilder]::new()
  $i = 0
  $prevKind = $null
  $toks |
    ? { $_.Kind -in @([TokenKind]::Comment, [TokenKind]::LineContinuation) } |
    % {
      $subStr = if ($prevKind -eq 'LineContinuation') {
        $text.Substring($i, $_.Extent.StartOffset - $i).TrimStart()
      } else {
        $text.Substring($i, $_.Extent.StartOffset - $i)
      }
      $cleanSb.Append($subStr) | Out-Null
      $i = $_.Extent.EndOffset
      $prevKind = $_.Kind
    }
  $rest = if ($prevKind -eq 'LineContinuation') {
    $text.Substring($i, $text.Length - $i).TrimStart()
  } else {
    $text.Substring($i, $text.Length - $i)
  }
  $cleanSb.Append($rest) | Out-Null
  $lines = $cleanSb.ToString().Split([Environment]::NewLine, [StringSplitOptions]::RemoveEmptyEntries) | 
    ? { $_ -notmatch '^\s+$' }
  $lines -join [Environment]::NewLine
}

function Invoke-ScriptMinifier {
  [Alias('Minify')]
  param (
    [Parameter(ParameterSetName = 'FromFile', Position = 0)]
    [Alias('f')]
    [string]$File,
    [Parameter(ParameterSetName = 'FromInput')]
    [Alias('c')]
    [string]$Command
  )
  $text = switch ($PSCmdlet.ParameterSetName) {
    'FromFile' {
      Get-Content -Path $File -Raw
    }
    'FromInput' {
      $Command
    }
  }
  $clean = Remove-ScriptTrivia $text
  $ast = [Parser]::ParseInput($clean, [ref]@(), [ref]@())
  [MinifyVisitor]::GetMinified($ast)
}
