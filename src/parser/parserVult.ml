(*
The MIT License (MIT)

Copyright (c) 2014 Leonardo Laguna Ruiz, Carl Jönsson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*)

(** Vult Parser *)

open LexerVult
open TypesVult
open Lexing
open ParserTypes
open TokenStream


module ExpTokenKind = struct
   type kind    = token_enum
   type content = exp
   type ttoken =
      {
         kind     : kind;
         value    : string;
         contents : content;
         loc      : Location.t;
      }
   let next     = next_token
   let kindStr  = kindToString
   let tokenStr = tokenToString
   let isEOF  x = x=EOF
   let getEOF   = EOF
end

module Stream = TokenStream(ExpTokenKind)

let splitOnDot s = CCString.Split.list_cpy "." s

let getErrorForToken (buffer:'kind stream) (message:string) : Error.t =
   Error.PointedError(Location.getNext buffer.prev.loc,message)

let getNotExpectedTokenError (token:'kind token) : Error.t =
   let message = Printf.sprintf "Not expecting to find %s" (tokenToString token) in
   Error.PointedError(Location.getNext token.loc,message)

let appendError (buffer:'kind stream) (error:Error.t) =
   buffer.errors <- error::buffer.errors

(** Skips one token *)
let skip (buffer:'kind stream) : unit =
   let _ = buffer.prev <- buffer.peeked in
   buffer.peeked <- next_token buffer.lines buffer.lexbuf

(** Returns the current token in the buffer *)
let current (buffer:'kind stream) : 'kind token =
   buffer.peeked

(** Returns the kind of the current token *)
let peekKind (buffer:'kind stream) : token_enum =
   (current buffer).kind

(** Consumes tokens until it finds the begining of a new statememt or the end of the current *)
let rec moveToNextStatement (buffer:'kind stream) : unit =
   match buffer.peeked.kind with
   | SEMI -> skip buffer
   | EOF -> ()
   | FUN | VAL
   | IF  | RET -> ()
   | RBRAC -> skip buffer
   | _ ->
      let _ = skip buffer in
      moveToNextStatement buffer

(** Checks that the next token matches the given kind and skip it *)
let consume (buffer:'kind stream) (kind:token_enum) : unit =
   match buffer.peeked with
   | t when t.kind = kind ->
      let _ = buffer.prev <- buffer.peeked in
      buffer.peeked <- next_token buffer.lines buffer.lexbuf
   | t when t.kind = EOF ->
      let expected = kindToString kind in
      let message = Printf.sprintf "Expecting a %s but the file ended" expected in
      raise (ParserError(getErrorForToken buffer message))
   | got_token ->
      let expected = kindToString kind in
      let got = tokenToString got_token in
      let message =  Printf.sprintf "Expecting a %s but got %s" expected got in
      raise (ParserError(getErrorForToken buffer message))

(** Checks that the next token matches *)
let expect (buffer:'kind stream) (kind:token_enum) : unit =
   match buffer.peeked with
   | t when t.kind=kind -> ()
   | t when t.kind = EOF ->
      let expected = kindToString kind in
      let message = Printf.sprintf "Expecting a %s but the file ended" expected in
      raise (ParserError(getErrorForToken buffer message))
   | got_token ->
      let expected = kindToString kind in
      let got = kindToString got_token.kind in
      let message = Printf.sprintf "Expecting a %s but got %s" expected got in
      raise (ParserError(getErrorForToken buffer message))

(** Optionally consumes the given token *)
let optConsume (buffer:'kind stream) (kind:token_enum) : unit =
   match buffer.peeked with
   | t when t.kind=kind ->
      skip buffer
   | _ -> ()

(** Returns an empty 'lexed_lines' type *)
let emptyLexedLines () =
   {
      current_line = Buffer.create 100;
      all_lines    = [];
   }

(** Creates a token stream given a string *)
let bufferFromString (str:string) : 'kind stream =
   let lexbuf = Lexing.from_string str in
   let lines = emptyLexedLines () in
   let first =  next_token lines lexbuf in
   { lexbuf = lexbuf; peeked = first; prev = first ; has_errors = false; errors= []; lines = lines }

(** Creates a token stream given a channel *)
let bufferFromChannel (chan:in_channel) (file:string) : 'kind stream =
   let lexbuf = Lexing.from_channel chan in
   let lines = emptyLexedLines () in
   lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = file };
   let first =  next_token lines lexbuf in
   { lexbuf = lexbuf; peeked = first; prev = first ; has_errors = false; errors = []; lines = lines }

(** Returns the location of an expression *)
let getExpLocation (e:exp) : Location.t =
   match e with
   | PUnit(loc)
   | PInt(_,loc)
   | PBool(_,loc)
   | PReal(_,loc) -> loc
   | PId(_,_,loc) -> loc
   | PUnOp(_,_,loc)
   | PBinOp(_,_,_,loc)
   | PCall(_,_,_,_,loc)
   | PIf(_,_,_,loc)
   | PGroup(_,loc)
   | PTuple(_,loc) -> loc
   | PEmpty -> Location.default
   | PSeq(_,_,loc) -> loc
   | PTyped(_,_,loc) -> loc

(** Returns the location of an statement *)
let getStmtLocation (s:stmt)  : Location.t =
   match s with
   | StmtVal(_,_,loc)
   | StmtMem(_,_,_,loc)
   | StmtTable(_,_,loc)
   | StmtReturn(_,loc)
   | StmtIf(_,_,_,loc)
   | StmtFun(_,_,_,_,_,loc)
   | StmtBind(_,_,loc) -> loc
   | StmtEmpty -> Location.default
   | StmtBlock(_,_,loc) -> loc
   | StmtWhile(_,_,loc) -> loc
   | StmtType(_,_,_,loc) -> loc
   | StmtAliasType(_,_,_,loc) -> loc

(** Returns the left binding powers of the token *)
let getLbp (token:'kind token) : int =
   match token.kind,token.value with
   | COLON,_ -> 10
   | COMMA,_ -> 20
   | OP,"||" -> 30
   | OP,"&&" -> 30
   | OP,"==" -> 40
   | OP,"!=" -> 40
   | OP,">"  -> 40
   | OP,"<"  -> 40
   | OP,">=" -> 40
   | OP,"<=" -> 40
   | OP,"+"  -> 50
   | OP,"-"  -> 50
   | OP,"*"  -> 60
   | OP,"/"  -> 60
   | OP,"%"  -> 60
   | _       -> 0

(** Parses an expression using a Pratt parser *)
let rec expression (rbp:int) (buffer:'kind stream) : exp =
   let current_token = current buffer in
   let _             = skip buffer in
   let left          = exp_nud buffer current_token in
   let next_token    = current buffer in
   let rec loop token left repeat =
      if repeat then
         let _         = skip buffer in
         let new_left  = exp_led buffer token left in
         let new_token = current buffer in
         loop new_token new_left (rbp < (getLbp new_token))
      else
         left
   in loop next_token left (rbp < (getLbp next_token))

(** Nud function for the Pratt parser *)
and exp_nud (buffer:'kind stream) (token:'kind token) : exp =
   match token.kind,token.value with
   | OP,"-" -> (* Unary minus *)
      unaryOp buffer token
   | ID,_   -> (* Id or function call *)
      let id = identifierToken buffer token in
      begin
         match peekKind buffer with
         | LPAREN ->
            functionCall buffer token id
         | COLON ->
            let _ = skip buffer in
            let type_exp = expression 20 buffer in
            PId(id,Some(type_exp),token.loc)
         | _ -> PId(id,None,token.loc)
      end
   | LPAREN,_ ->
      begin
         let start_loc = token.loc in
         match peekKind buffer with
         | RPAREN ->
            let _ = skip buffer in
            PUnit(start_loc)
         | _ ->
            let e = expression 0 buffer in
            let _ = consume buffer RPAREN in
            PGroup(e,start_loc)
      end
   | INT,_   -> PInt(int_of_string token.value,token.loc)
   | REAL,_  -> PReal(float_of_string token.value,token.loc)
   | TRUE,_  -> PBool(true,token.loc)
   | FALSE,_ -> PBool(false,token.loc)
   | IF,_ ->
      let cond = expression 0 buffer in
      let _ = consume buffer THEN in
      let then_exp = expression 0 buffer in
      let _ = consume buffer ELSE in
      let else_exp = expression 0 buffer in
      PIf(cond,then_exp,else_exp,token.loc)
   | LSEQ,_ ->
      let stmts = pseqList buffer in
      PSeq(None,stmts,token.loc)
   | _ ->
      let message = getNotExpectedTokenError token in
      raise (ParserError(message))

(** Led function for the Pratt parser *)
and exp_led (buffer:'kind stream) (token:'kind token) (left:exp) : exp =
   match token.kind,token.value with
   | OP,_ -> (* Binary operators *)
      binaryOp buffer token left
   | COMMA,_ ->
      pair buffer token left
   | COLON,_ ->
      typedId buffer token left
   (*| _ -> token*)

(** <pair> :=  <expression>  ',' <expression> [ ',' <expression> ] *)
and pair (buffer:'kind stream) (token:'kind token) (left:exp) : exp =
   let right = expression (getLbp token) buffer in
   let getElems e =
      match e with
      | PTuple(elems,_) -> elems
      | _ -> [e]
   in
   let elems1 = left |> getElems in
   let elems2 = right |> getElems in
   let start_loc = getExpLocation left in
   PTuple(elems1@elems2,start_loc)

(** <typedId> := <expression> : <expression> *)
and typedId (buffer:'kind stream) (token:'kind token) (left:exp) : exp =
   let right = expression 20 buffer in
   PTyped(left,right,token.loc)

(** <functionCall> := <identifier> '(' <expressionList> ')' *)
and functionCall (buffer:'kind stream) (token:'kind token) (id:identifier) : exp =
   let _ = skip buffer in
   let args =
      match peekKind buffer with
      | RPAREN -> []
      | _ -> expressionList buffer
   in
   let _ = consume buffer RPAREN in
   PCall(None,id,args,[],token.loc)

(** <unaryOp> := OP <expression> *)
and unaryOp (buffer:'kind stream) (token:'kind token) : exp =
   let right = expression 70 buffer in
   PUnOp(token.value,right,token.loc)

(** <binaryOp> := <expression> OP <expression> *)
and binaryOp (buffer:'kind stream) (token:'kind token) (left:exp) : exp =
   let right = expression (getLbp token) buffer in
   PBinOp(token.value,left,right,token.loc)

(** <expressionList> := <expression> [',' <expression> ] *)
and expressionList (buffer:'kind stream) : exp list =
   let rec loop acc =
      (* power of 20 avoids returning a tuple instead of a list*)
      let e = expression 20 buffer in
      match peekKind buffer with
      | COMMA ->
         let _ = skip buffer in
         loop (e::acc)
      | _ -> List.rev (e::acc)
   in loop []

(** namedId := <ID> [ ':' <ID>]  *)
and namedId (buffer:'kind stream) : named_id =
   let _     = expect buffer ID in
   let token = current buffer in
   let _     = skip buffer in
   match peekKind buffer with
   | COLON ->
      let _     = skip buffer in
      let e = expression 20 buffer in
      NamedId(splitOnDot token.value,e,token.loc)
   | _ -> SimpleId(splitOnDot token.value,token.loc)

and identifierToken (buffer:'kind stream) (token:'kind token) : identifier =
   splitOnDot token.value

and identifier (buffer:'kind stream) : identifier =
   let _     = expect buffer ID in
   let token = current buffer in
   let _     = skip buffer in
   identifierToken buffer token

(** namedIdList := namedId [',' namedId ] *)
and namedIdList (buffer:'kind stream) : named_id list =
   match peekKind buffer with
   | ID ->
      let first = namedId buffer in
      begin
         match peekKind buffer with
         | COMMA ->
            let _ = consume buffer COMMA in
            first::(namedIdList buffer)
         | _ -> [first]
      end
   | _ -> []

(** <optStartValue> := '(' <expression> ')' *)
and optStartValue (buffer:'kind stream) : exp option =
   match peekKind buffer with
   | LPAREN ->
      let _ = consume buffer LPAREN in
      let e = expression 0 buffer in
      let _ = consume buffer RPAREN in
      Some(e)
   | _ -> None

(** initExpression := '(' expression ')'*)
and initExpression (buffer:'kind stream) : exp option =
   match peekKind buffer with
   | AT ->
      let _ = skip buffer in
      let e = expression 0 buffer in
      Some(e)
   | _ -> None

(** <statement> := | 'val' <valBindList> ';' *)
and stmtVal (buffer:'kind stream) : stmt =
   let start_loc = buffer.peeked.loc in
   let _ = consume buffer VAL in
   let lhs = expression 0 buffer in
   (* TODO: Add check of lhs *)
   match peekKind buffer with
   | EQUAL ->
      let _   = skip buffer in
      let rhs = expression 0 buffer in
      let _   = consume buffer SEMI in
      StmtVal(lhs,Some(rhs),start_loc)
   | _ ->
      let _ = consume buffer SEMI in
      StmtVal(lhs,None,start_loc)

(** <statement> := | 'mem' <valBindList> ';' *)
and stmtMem (buffer:'kind stream) : stmt =
   let start_loc = buffer.peeked.loc in
   let _    = consume buffer MEM in
   let lhs  = expression 0 buffer in
   let init = initExpression buffer in
   (* TODO: Add check of lhs *)
   match peekKind buffer with
   | EQUAL ->
      let _   = skip buffer in
      let rhs = expression 0 buffer in
      let _   = consume buffer SEMI in
      StmtMem(lhs,init,Some(rhs),start_loc)
   | _ ->
      let _ = consume buffer SEMI in
      StmtMem(lhs,init,None,start_loc)

and stmtTab (buffer: 'kind stream) : stmt =
   let start_loc = buffer.peeked.loc in
   let _     = consume buffer TABLE in
   let name  = identifier buffer in
   let _     = consume buffer EQUAL in
   let _     = consume buffer LARR in
   let elems = expressionList buffer in
   let _     = consume buffer RARR in
   let _ = consume buffer SEMI in
   StmtTable(name,elems,start_loc)

(** <statement> := | 'return' <expression> ';' *)
and stmtReturn (buffer:'kind stream) : stmt =
   let start_loc = buffer.peeked.loc in
   let _ = consume buffer RET in
   let e = expression 0 buffer in
   let _ = consume buffer SEMI in
   StmtReturn(e,start_loc)

and stmtBind (buffer:'kind stream) : stmt =
   let e1 = expression 0 buffer in
   let start_loc = getExpLocation e1 in
   match peekKind buffer with
   | EQUAL ->
      let _ = consume buffer EQUAL in
      let e2 = expression 0 buffer in
      let _ = consume buffer SEMI in
      StmtBind(e1,e2,start_loc)
   | SEMI ->
      let _ = consume buffer SEMI in
      StmtBind(PUnit(start_loc),e1,start_loc)
   | kind ->
      let expected = kindToString EQUAL in
      let got = kindToString kind in
      let message = Printf.sprintf "Expecting a %s while trying to parse a binding (%s = ...) but got %s" expected (PrintTypes.expressionStr e1) got in
      raise (ParserError(getErrorForToken buffer message))

(** <statement> := 'if' '(' <expression> ')' <statementList> ['else' <statementList> ]*)
and stmtIf (buffer:'kind stream) : stmt =
   let _    = consume buffer IF in
   let _    = consume buffer LPAREN in
   let cond = expression 0 buffer in
   let _    = consume buffer RPAREN in
   let tstm = stmtList buffer in
   let start_loc = getExpLocation cond in
   match peekKind buffer with
   | ELSE ->
      let _ = consume buffer ELSE in
      let fstm = stmtList buffer in
      StmtIf(cond,tstm,Some(fstm),start_loc)
   | _ -> StmtIf(cond,tstm,None,start_loc)

(** 'fun' <identifier> '(' <namedIdList> ')' <stmtList> *)
and stmtFunction (buffer:'kind stream) : stmt =
   let isjoin = match peekKind buffer with | AND -> true | _ -> false in
   let _      = skip buffer in
   let name   = identifier buffer in
   let token  = current buffer in
   let _      = consume buffer LPAREN in
   let args   =
      match peekKind buffer with
      | RPAREN -> []
      | _ -> namedIdList buffer
   in
   let _    = consume buffer RPAREN in
   let type_exp =
      match peekKind buffer with
      | COLON ->
         let _ = skip buffer in
         Some(expression 0 buffer)
      | _ -> None
   in
   let body = stmtList buffer in
   let start_loc = token.loc in
   let attr = if isjoin then [JoinFunction] else [] in
   StmtFun(name,args,body,type_exp,attr,start_loc)

(** 'type' <identifier> '(' <namedIdList> ')' <valDeclList> *)
and stmtType (buffer:'kind stream) : stmt =
   let _     = consume buffer TYPE in
   let name  = identifier buffer in
   let token = current buffer in
   let start_loc = token.loc in
   let args  =
      match peekKind buffer with
      | LPAREN ->
         let _    = skip buffer in
         let args = namedIdList buffer in
         let _    = consume buffer RPAREN in
         args
      | _ -> []
   in
   match peekKind buffer with
   | COLON ->
      let _ = skip buffer in
      let type_exp = expression 10 buffer in
      let _ = optConsume buffer SEMI in
      StmtAliasType(name,args,type_exp,start_loc)
   | LBRAC ->
      let _        = skip buffer in
      let val_decl = valDeclList buffer in
      let _        = consume buffer RBRAC in
      StmtType(name,args,val_decl,start_loc)
   | _ ->
      let got = tokenToString buffer.peeked in
      let message = Printf.sprintf "Expecting a list of value declarations '{ val x:... }' or a type alias ': type' but got %s" got  in
      raise (ParserError(getErrorForToken buffer message))

and valDeclList (buffer:'kind stream) : val_decl list =
   let rec loop acc =
      match peekKind buffer with
      | VAL ->
         let decl = valDecl buffer in
         let _    = consume buffer SEMI in
         loop (decl::acc)
      | _ -> List.rev acc
   in loop []

and valDecl (buffer:'kind stream) : val_decl =
   let _         = expect buffer VAL in
   let token     = current buffer in
   let start_loc = token.loc in
   let _         = skip buffer in
   let id        = identifier buffer in
   let _         = consume buffer COLON in
   let val_type  = expression 10 buffer in
   id,val_type,start_loc

(** 'while' (<expression>) <stmtList> *)
and stmtWhile (buffer:'kind stream) : stmt =
   let start_loc = buffer.peeked.loc in
   let _ = consume buffer WHILE in
   let _ = consume buffer LPAREN in
   let cond = expression 0 buffer in
   let _    = consume buffer RPAREN in
   let tstm = stmtList buffer in
   StmtWhile(cond,tstm,start_loc)

(** <statement> := ... *)
and stmt (buffer:'kind stream) : stmt =
   try
      match peekKind buffer with
      | VAL   -> stmtVal     buffer
      | MEM   -> stmtMem     buffer
      | RET   -> stmtReturn  buffer
      | IF    -> stmtIf      buffer
      | FUN   -> stmtFunction buffer
      | AND   -> stmtFunction buffer
      | WHILE -> stmtWhile    buffer
      | TYPE  -> stmtType     buffer
      | TABLE -> stmtTab      buffer
      | _     -> stmtBind     buffer
   with
   | ParserError(error) ->
      let _ = appendError buffer error in
      let _ = moveToNextStatement buffer in
      let _ = buffer.has_errors<-true in
      StmtEmpty

(** <statementList> := LBRACK <statement> [<statement>] RBRACK *)
and stmtList (buffer:'kind stream) : stmt =
   let start_loc = buffer.peeked.loc in
   let rec loop acc =
      match peekKind buffer with
      | RBRAC ->
         let end_loc = buffer.peeked.loc in
         let loc = Location.merge start_loc end_loc in
         let _ = skip buffer in
         StmtBlock(None,List.rev acc,loc)
      | EOF ->
         let _ = expect buffer RBRAC in
         StmtBlock(None,[],start_loc)
      | _ ->
         let s = stmt buffer in
         loop (s::acc)
   in
   match peekKind buffer with
   | LBRAC ->
      let _ = skip buffer in
      loop []
   | _ ->
      let s = stmt buffer in
      let loc = getStmtLocation s in
      StmtBlock(None,[s],loc)

(** <statementList> :=  LSEQ <statement> [<statement>] RSEQ
    When called in exp_nud function LSEQ is already consumed *)
and pseqList (buffer:'kind stream) : stmt list =
   let rec loop acc =
      match peekKind buffer with
      | RSEQ ->
         let _ = skip buffer in
         List.rev acc
      | EOF ->
         let _ = expect buffer RSEQ in
         []
      | _ ->
         let s = stmt buffer in
         loop (s::acc)
   in loop []

(** Parses an expression given a string *)
let parseExp (s:string) : exp =
   let buffer = bufferFromString s in
   expression 0 buffer

(** Parses an statement given a string *)
let parseStmt (s:string) : stmt =
   let buffer = bufferFromString s in
   let result = stmt buffer in
   result

(** Parses a list of statements given a string *)
let parseStmtList (s:string) : stmt =
   let buffer = bufferFromString s in
   let result = stmtList buffer in
   result

(** Parses the given expression and prints it *)
let parseDumpExp (s:string) : string =
   let e = parseExp s in
   PrintTypes.expressionStr e

(** Parses a list of statements and prints them *)
let parseDumpStmtList (s:string) : string =
   let e = parseStmtList s in
   PrintTypes.stmtStr e

(** Parses a buffer containing a list of statements and returns the results *)
let parseBuffer (file:string) (buffer) : parser_results =
   try
      let rec loop acc =
         match peekKind buffer with
         | EOF -> List.rev acc
         | _ -> loop ((stmtList buffer)::acc)
      in
      let result = loop [] in
      let all_lines = getFileLines buffer.lines in
      if buffer.has_errors then
         {
            presult = `Error(List.rev buffer.errors);
            lines = all_lines;
            file = file;
         }
      else
         {
            presult = `Ok(result);
            lines = all_lines;
            file = file;
         }
   with
   | ParserError(error) ->
      let all_lines = getFileLines buffer.lines in
      {
         presult = `Error([error]);
         lines = all_lines;
         file = file;
      }
   | _ ->
      let all_lines = getFileLines buffer.lines in
      {
         presult = `Error([Error.SimpleError("Failed to parse the file")]);
         lines = all_lines;
         file = file;
      }

(** Parses a file containing a list of statements and returns the results *)
let parseFile (filename:string) : parser_results =
   let chan = open_in filename in
   let buffer = bufferFromChannel chan filename in
   let result = parseBuffer filename buffer in
   let _ = close_in chan in
   result

(** Parses a string containing a list of statements and returns the results *)
let parseString (text:string) : parser_results =
   let buffer = bufferFromString text in
   let result = parseBuffer "live.vult" buffer in
   result
