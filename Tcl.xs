/* 
 * Tcl.xs --
 *
 *	This file contains XS code for the Perl's Tcl bridge module.
 *
 * Copyright (c) 1994-1997, Malcolm Beattie
 * Copyright (c) 2003-2004, Vadim Konovalov
 * Copyright (c) 2004 ActiveState Corp., a division of Sophos PLC
 *
 * RCS: @(#) $Id$
 */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/*
 * Until we update for 8.4 CONST-ness
 */
#define USE_NON_CONST

/*
 * Both Perl and Tcl use this macro
 */
#undef STRINGIFY

#include <tcl.h>

#define Tcl_new(class) Tcl_CreateInterp()
#define Tcl_result(interp) Tcl_GetStringResult(interp)
#define Tcl_DESTROY(interp) Tcl_DeleteInterp(interp)

typedef Tcl_Interp *Tcl;
typedef AV *Tcl__Var;

static int findexecutable_called = 0;

/*
 * Variables denoting the Tcl object types defined in the core.
 */

static Tcl_ObjType *tclBooleanTypePtr = NULL;
static Tcl_ObjType *tclByteArrayTypePtr = NULL;
static Tcl_ObjType *tclDoubleTypePtr = NULL;
static Tcl_ObjType *tclIntTypePtr = NULL;
static Tcl_ObjType *tclListTypePtr = NULL;
static Tcl_ObjType *tclStringTypePtr = NULL;
static Tcl_ObjType *tclWideIntTypePtr = NULL;

static int
has_highbit(CONST char *s,int l)
{
    CONST char *e = s+l;
    while (s < e) {
	if (*s++ & 0x80)
	    return 1;
    }
    return 0;
}

static SV *
SvFromTclObj(Tcl_Obj *objPtr)
{
    SV *sv;
    int len;
    char *str;

    if (tclBooleanTypePtr == NULL) {
	tclBooleanTypePtr   = Tcl_GetObjType("boolean");
	tclByteArrayTypePtr = Tcl_GetObjType("bytearray");
	tclDoubleTypePtr    = Tcl_GetObjType("double");
	tclIntTypePtr       = Tcl_GetObjType("int");
	tclListTypePtr      = Tcl_GetObjType("list");
	tclStringTypePtr    = Tcl_GetObjType("string");
	tclWideIntTypePtr   = Tcl_GetObjType("wideInt");
    }

    if (objPtr->typePtr == tclIntTypePtr) {
	return newSViv(objPtr->internalRep.longValue);
    }
    else if (objPtr->typePtr == tclDoubleTypePtr) {
	return newSVnv(objPtr->internalRep.doubleValue);
    }
    else if (objPtr->typePtr == tclBooleanTypePtr) {
	return newSViv((objPtr->internalRep.longValue != 0));
    }
    else if (objPtr->typePtr == tclByteArrayTypePtr) {
	str = Tcl_GetByteArrayFromObj(objPtr, &len);
	sv = newSVpvn(str, len);
    }
    /* tclStringTypePtr is true unicode */
    /* tclWideIntTypePtr is 64-bit int */
    /* tclListTypePtr should become an AV */
    else {
	str = Tcl_GetStringFromObj(objPtr, &len);
	sv = newSVpvn(str, len);
	/* should turn on, but let's check this first for efficiency */
	if (len && has_highbit(str, len)) {
	    SvUTF8_on(sv);
	}
    }
    return sv;
}

static Tcl_Obj *
TclObjFromSv(SV *sv)
{
    Tcl_Obj *objPtr = NULL;

    if (SvROK(sv) && SvTYPE(sv) == SVt_PVAV) {
	AV *av    = (AV *) SvRV(sv);
	I32 avlen = av_len(av);
	int i;

	objPtr = Tcl_NewListObj(0, (Tcl_Obj **) NULL);

	if (avlen == -1) { avlen = 0; }
	for (i = 0; i < avlen; i++) {
	    sv = sv_mortalcopy(*av_fetch(av, i, FALSE));
	    Tcl_ListObjAppendElement(NULL, objPtr, TclObjFromSv(sv));
	}
    }
    else if (SvPOK(sv)) {
	STRLEN length;
	char *str = SvPV(sv, length);
	objPtr = Tcl_NewStringObj(str, length);
    }
    else if (SvNOK(sv)) {
	objPtr = Tcl_NewDoubleObj(SvNV(sv));
    }
    else if (SvUOK(sv)) {
	objPtr = Tcl_NewIntObj((int)SvUV(sv));
    }
    else if (SvIOK(sv)) {
	objPtr = Tcl_NewIntObj(SvIV(sv));
    }
    else {
	/*
	 * Catch-all
	 */
	STRLEN length;
	char *str = SvPV(sv, length);
	objPtr = Tcl_NewStringObj(str, length);
    }

    return objPtr;
}

int Tcl_PerlCallWrapper(ClientData clientData, Tcl_Interp *interp,
	int argc, char **argv)
{
    dSP;
    AV *av = (AV *) clientData;
    I32 count;
    SV *sv;
    int rc;

    /*
     * av = [$perlsub, $realclientdata, $interp, $deleteProc]
     * (where $deleteProc is optional but we don't need it here anyway)
     */

    if (AvFILL(av) != 2 && AvFILL(av) != 3)
	croak("bad clientdata argument passed to Tcl_PerlCallWrapper");

    ENTER;
    SAVETMPS;

    PUSHMARK(sp);
    EXTEND(sp, argc + 2);
    PUSHs(sv_mortalcopy(*av_fetch(av, 1, FALSE)));
    PUSHs(sv_mortalcopy(*av_fetch(av, 2, FALSE)));
    while (argc--)
	PUSHs(sv_2mortal(newSVpv(*argv++, 0)));
    PUTBACK;
    count = perl_call_sv(*av_fetch(av, 0, FALSE), G_SCALAR);
    SPAGAIN;
    if (count != 1)
	croak("perl sub bound to Tcl proc didn't return exactly 1 argument");

    sv = POPs;
    PUTBACK;
    
    /* rc = SvOK(sv) ? TCL_OK : TCL_ERROR; <-- elder version. but nothing wrong
     * for callback to return undef. Hence following: */
    rc = TCL_OK;
    
    if (SvOK(sv)) {
	Tcl_SetResult(interp, SvPV_nolen(sv), TCL_VOLATILE);
    }
    /*
     * If the routine returned undef, it indicates that it has done the
     * SetResult itself and that we should return TCL_ERROR
     */

    FREETMPS;
    LEAVE;
    return rc;
}

void
Tcl_PerlCallDeleteProc(ClientData clientData)
{
    AV *av = (AV *) clientData;
    
    /*
     * av = [$perlsub, $realclientdata, $interp, $deleteProc]
     * (where $deleteProc is optional but we don't need it here anyway)
     */

    if (AvFILL(av) == 3) {
	dSP;

	PUSHMARK(sp);
	EXTEND(sp, 1);
	PUSHs(sv_mortalcopy(*av_fetch(av, 1, FALSE)));
	PUTBACK;
	(void) perl_call_sv(*av_fetch(av, 3, FALSE), G_SCALAR|G_DISCARD);
    }
    else if (AvFILL(av) != 2)
	croak("bad clientdata argument passed to Tcl_PerlCallDeleteProc");

    SvREFCNT_dec((AV *) clientData);
}

void
prepare_Tcl_result(interp, caller)
Tcl interp;
char *caller;
{
    dSP;
    Tcl_Obj *objPtr, **objv;
    int gimme, objc, i;

    objPtr = Tcl_GetObjResult(interp);

    gimme = GIMME_V;
    if (gimme == G_SCALAR) {
	/*
	 * This checks Tcl_Obj type
	 */
	PUSHs(sv_2mortal(SvFromTclObj(objPtr)));
    }
    else if (gimme == G_ARRAY) {
	if (Tcl_ListObjGetElements(interp, objPtr, &objc, &objv)
		!= TCL_OK) {
	    croak("%s called in list context did not return a valid Tcl list",
		    caller);
	}
	if (objc) {
	    EXTEND(sp, objc);
	    for (i = 0; i < objc; i++) {
		/*
		 * This checks Tcl_Obj type
		 */
		PUSHs(sv_2mortal(SvFromTclObj(objv[i])));
	    }
	}
    }
    else {
	/* G_VOID context - ignore result */
    }
    PUTBACK;
    return;
}

char *
var_trace(ClientData clientData, Tcl_Interp *interp,
	char *name1, char *name2, int flags)
{
    if (flags & TCL_TRACE_READS) {
        warn("TCL_TRACE_READS\n");
    }
    else if (flags & TCL_TRACE_WRITES) {
        warn("TCL_TRACE_WRITES\n");
    }
    else if (flags & TCL_TRACE_ARRAY) {
        warn("TCL_TRACE_ARRAY\n");
    }
    else if (flags & TCL_TRACE_UNSETS) {
        warn("TCL_TRACE_UNSETS\n");
    }
    return 0;
}

MODULE = Tcl	PACKAGE = Tcl	PREFIX = Tcl_

Tcl
Tcl_new(class = "Tcl")
	char *	class

char *
Tcl_result(interp)
	Tcl	interp

void
Tcl_Eval(interp, script)
	Tcl	interp
	SV *	script
	SV *	interpsv = ST(0);
	STRLEN	length = NO_INIT
	char *cscript = NO_INIT
    PPCODE: 
	(void) sv_2mortal(SvREFCNT_inc(interpsv));
	PUTBACK;
	Tcl_ResetResult(interp);
	/* sv_mortalcopy here prevents stringifying script - necessary ?? */
	cscript = SvPV(sv_mortalcopy(script), length);
	if (Tcl_EvalEx(interp, cscript, length, 0) != TCL_OK) {
	    croak(Tcl_GetStringResult(interp));
	}
	prepare_Tcl_result(interp, "Tcl::Eval");
	SPAGAIN;

void
Tcl_EvalFile(interp, filename)
	Tcl	interp
	char *	filename
	SV *	interpsv = ST(0);
    PPCODE:
	(void) sv_2mortal(SvREFCNT_inc(interpsv));
	PUTBACK;
	Tcl_ResetResult(interp);
	if (Tcl_EvalFile(interp, filename) != TCL_OK) {
	    croak(Tcl_GetStringResult(interp));
	}
	prepare_Tcl_result(interp, "Tcl::EvalFile");
	SPAGAIN;

void
Tcl_GlobalEval(interp, script)
	Tcl	interp
	SV *	script
	SV *	interpsv = ST(0);
	STRLEN	length = NO_INIT
	char *cscript = NO_INIT
    PPCODE:
	(void) sv_2mortal(SvREFCNT_inc(interpsv));
	PUTBACK;
	Tcl_ResetResult(interp);
	/* sv_mortalcopy here prevents stringifying script - necessary ?? */
	cscript = SvPV(sv_mortalcopy(script), length);
	if (Tcl_EvalEx(interp, cscript, length, TCL_EVAL_GLOBAL) != TCL_OK) {
	    croak(Tcl_GetStringResult(interp));
	}
	prepare_Tcl_result(interp, "Tcl::GlobalEval");
	SPAGAIN;

void
Tcl_EvalFileHandle(interp, handle)
	Tcl	interp
	PerlIO*	handle
	int	append = 0;
	SV *	interpsv = ST(0);
	SV *	sv = sv_newmortal();
	char *	s = NO_INIT
    PPCODE:
	(void) sv_2mortal(SvREFCNT_inc(interpsv));
	PUTBACK;
        while (s = sv_gets(sv, handle, append))
	{
            if (!Tcl_CommandComplete(s))
		append = 1;
	    else
	    {
		Tcl_ResetResult(interp);
		if (Tcl_Eval(interp, s) != TCL_OK)
		    croak(Tcl_GetStringResult(interp));
		append = 0;
	    }
	}
	if (append)
	    croak("unexpected end of file in Tcl::EvalFileHandle");
	prepare_Tcl_result(interp, "Tcl::EvalFileHandle");
	SPAGAIN;

void
Tcl_icall(interp, proc, ...)
	Tcl		interp
	SV *		proc
	Tcl_CmdInfo	cmdinfo = NO_INIT
        static int	i, result = NO_INIT
        static STRLEN	length = NO_INIT
	static int	argc = NO_INIT
	static Tcl_Obj **   objv = NO_INIT
	static char **	argv = NO_INIT
	static int	argv_cursize = 0;
	static char *	str = NO_INIT
    PPCODE:
	argc = items-1;
	if (argv_cursize == 0) {
	    argv_cursize = (items < 16) ? 16 : items;
	    New(666, argv, argv_cursize, char *);
	    New(666, objv, argv_cursize, Tcl_Obj *);
	}
	else if (argv_cursize < items) {
	    argv_cursize = items;
	    Renew(argv, argv_cursize, char *);
	    Renew(objv, argv_cursize, Tcl_Obj *);
	}
	SP++;			/* bypass the interp argument */
	proc = sv_mortalcopy(*++SP);  /* get name of Tcl command into argv[0] */
	argv[0] = SvPV(proc, length);
	if (!Tcl_GetCommandInfo(interp, argv[0], &cmdinfo)) {
	    croak("Tcl procedure '%s' not found",argv[0]);
	}

	Tcl_ResetResult(interp);

        if (cmdinfo.objProc) {
            /*
	     * We might want to check that this isn't TclInvokeStringCommand,
	     * which just means we waste time making Tcl_Obj's.
	     *
	     * Emulate TclInvokeObjectCommand (from Tcl), namely create the
	     * object argument array "objv" before calling right procedure
             */
	    objv[0] = Tcl_NewStringObj(argv[0], length);
            for (i = 1;  i < argc;  i++) {
		proc = sv_mortalcopy(*++SP);
#if 1
		/*
		 * Use efficient Sv to Tcl_Obj conversion
		 */
        	objv[i] = TclObjFromSv(proc);
#else
        	str = SvPV(proc, length);
        	objv[i] = Tcl_NewStringObj(str,length);
#endif
        	Tcl_IncrRefCount(objv[i]);
            }
	    SP -= items;
	    PUTBACK;

	    /*
	     * Invoke the command's object-based Tcl_ObjCmdProc.
	     */
            result = (*cmdinfo.objProc)(cmdinfo.objClientData, interp,
		    argc, objv);

	    /*
	     * Decrement the ref counts for the argument objects created above
	     */
            for (i = 0;  i < argc;  i++) {
        	Tcl_DecrRefCount(objv[i]);
	    }
        }
        else {
	    /* 
	     * we have cmdinfo.objProc==0
	     * prepare string arguments into argv (1st is already done)
	     * and call found procedure
	     */
	    for (i = 1; i < argc; i++) {
		/*
		 * Use proc as a spare SV* variable: macro SvPV evaluates
		 * its arguments more than once.
		 */
		proc = sv_mortalcopy(*++SP);
		argv[i] = SvPV_nolen(proc);
	    }
	    SP -= items;
	    PUTBACK;
            /*
	     * Invoke the command's procedure
	     */
            result = (*cmdinfo.proc)(cmdinfo.clientData, interp, argc, argv);
        }
        if (result != TCL_OK) {
       	    croak(Tcl_GetStringResult(interp));
	}
	prepare_Tcl_result(interp, "Tcl::call");
        SPAGAIN;

void
Tcl_DESTROY(interp)
	Tcl	interp

void
Tcl_Init(interp)
	Tcl	interp
    CODE:
    	if (!findexecutable_called) {
	    Tcl_FindExecutable("."); /* TODO (?) place here $^X ? */
	}
	if (Tcl_Init(interp) != TCL_OK)
	    croak(Tcl_GetStringResult(interp));

void
Tcl_CreateCommand(interp,cmdName,cmdProc,clientData=&PL_sv_undef,deleteProc=Nullsv)
	Tcl	interp
	char *	cmdName
	SV *	cmdProc
	SV *	clientData
	SV *	deleteProc
    CODE:
	if (SvIOK(cmdProc))
	    Tcl_CreateCommand(interp, cmdName, (Tcl_CmdProc *) SvIV(cmdProc),
			      (ClientData) SvIV(clientData), NULL);
	else
	{
	    AV *av = (AV *) SvREFCNT_inc((SV *) newAV());
	    av_store(av, 0, newSVsv(cmdProc));
	    av_store(av, 1, newSVsv(clientData));
	    av_store(av, 2, newSVsv(ST(0)));
	    if (deleteProc)
		av_store(av, 3, newSVsv(deleteProc));
	    Tcl_CreateCommand(interp, cmdName, Tcl_PerlCallWrapper,
			      (ClientData) av, Tcl_PerlCallDeleteProc);
	}
	ST(0) = &PL_sv_yes;
	XSRETURN(1);

void
Tcl_SetResult(interp, str)
	Tcl	interp
	char *	str
    CODE:
	Tcl_SetResult(interp, str, TCL_VOLATILE);
	ST(0) = ST(1);
	XSRETURN(1);

void
Tcl_AppendElement(interp, str)
	Tcl	interp
	char *	str

void
Tcl_ResetResult(interp)
	Tcl	interp

void
Tcl_FindExecutable(argv)
	char *	argv
    CODE:
    	Tcl_FindExecutable(argv);
	findexecutable_called = 1;


char *
Tcl_AppendResult(interp, ...)
	Tcl	interp
	int	i = NO_INIT
    CODE:
	for (i = 1; i <= items; i++)
	    Tcl_AppendResult(interp, SvPV_nolen(ST(i)), NULL);
	RETVAL = Tcl_GetStringResult(interp);
    OUTPUT:
	RETVAL

int
Tcl_DeleteCommand(interp, cmdName)
	Tcl	interp
	char *	cmdName
    CODE:
	RETVAL = Tcl_DeleteCommand(interp, cmdName) == 0;
    OUTPUT:
	RETVAL

void
Tcl_SplitList(interp, str)
	Tcl		interp
	char *		str
	int		argc = NO_INIT
	char **		argv = NO_INIT
	char **		tofree = NO_INIT
    PPCODE:
	if (Tcl_SplitList(interp, str, &argc, &argv) == TCL_OK)
	{
	    tofree = argv;
	    EXTEND(sp, argc);
	    while (argc--)
		PUSHs(sv_2mortal(newSVpv(*argv++, 0)));
	    ckfree((char *) tofree);
	}

char *
Tcl_SetVar(interp, varname, value, flags = 0)
	Tcl	interp
	char *	varname
	char *	value
	int	flags

char *
Tcl_SetVar2(interp, varname1, varname2, value, flags = 0)
	Tcl	interp
	char *	varname1
	char *	varname2
	char *	value
	int	flags

char *
Tcl_GetVar(interp, varname, flags = 0)
	Tcl	interp
	char *	varname
	int	flags

char *
Tcl_GetVar2(interp, varname1, varname2, flags = 0)
	Tcl	interp
	char *	varname1
	char *	varname2
	int	flags

int
Tcl_UnsetVar(interp, varname, flags = 0)
	Tcl	interp
	char *	varname
	int	flags
    CODE:
	RETVAL = Tcl_UnsetVar(interp, varname, flags) == TCL_OK;
    OUTPUT:
	RETVAL

int
Tcl_UnsetVar2(interp, varname1, varname2, flags = 0)
	Tcl	interp
	char *	varname1
	char *	varname2
	int	flags
    CODE:
	RETVAL = Tcl_UnsetVar2(interp, varname1, varname2, flags) == TCL_OK;
    OUTPUT:
	RETVAL

void
Tcl_perl_attach(interp, name)
	Tcl	interp
	char *	name
    PPCODE:
	PUTBACK;
	/* create Tcl array */
	Tcl_SetVar2(interp, name, 0, "", 0);
	/* start trace on it */
	if (Tcl_TraceVar2(interp, name, 0,
	    TCL_TRACE_READS | TCL_TRACE_WRITES | TCL_TRACE_UNSETS |
	    TCL_TRACE_ARRAY,
	    &var_trace,
	    NULL /* clientData*/
	    ) != TCL_OK) {
	    croak(Tcl_GetStringResult(interp));
	}
	if (Tcl_TraceVar(interp, name,
	    TCL_TRACE_READS | TCL_TRACE_WRITES | TCL_TRACE_UNSETS,
	    &var_trace,
	    NULL /* clientData*/
	    ) != TCL_OK) {
	    croak(Tcl_GetStringResult(interp));
	}
        SPAGAIN;
       
void
Tcl_perl_detach(interp, name)
	Tcl	interp
	char *	name
    PPCODE:
	PUTBACK;
	/* stop trace */
        Tcl_UntraceVar2(interp, name, 0,
	    TCL_TRACE_READS|TCL_TRACE_WRITES|TCL_TRACE_UNSETS,
	    &var_trace,
	    NULL /* clientData*/
	    );
        SPAGAIN;

MODULE = Tcl		PACKAGE = Tcl::Var

char *
FETCH(av, key = NULL)
	Tcl::Var	av
	char *		key
	SV *		sv = NO_INIT
	Tcl		interp = NO_INIT
	char *		varname1 = NO_INIT
	int		flags = 0;
    CODE:
	/*
	 * This handles both hash and scalar fetches. The blessed object
	 * passed in is [$interp, $varname, $flags] ($flags optional).
	 */
	if (AvFILL(av) != 1 && AvFILL(av) != 2)
	    croak("bad object passed to Tcl::Var::FETCH");
	sv = *av_fetch(av, 0, FALSE);
	if (sv_isa(sv, "Tcl"))
	{
	    IV tmp = SvIV((SV *) SvRV(sv));
	    interp = (Tcl) tmp;
	}
	else
	    croak("bad object passed to Tcl::Var::FETCH");
	if (AvFILL(av) == 2)
	    flags = (int) SvIV(*av_fetch(av, 2, FALSE));
	varname1 = SvPV_nolen(*av_fetch(av, 1, FALSE));
	RETVAL = key ? Tcl_GetVar2(interp, varname1, key, flags)
		     : Tcl_GetVar(interp, varname1, flags);
    OUTPUT:
	RETVAL

void
STORE(av, str1, str2 = NULL)
	Tcl::Var	av
	char *		str1
	char *		str2
	SV *		sv = NO_INIT
	Tcl		interp = NO_INIT
	char *		varname1 = NO_INIT
	int		flags = 0;
    CODE:
	/*
	 * This handles both hash and scalar stores. The blessed object
	 * passed in is [$interp, $varname, $flags] ($flags optional).
	 */
	if (AvFILL(av) != 1 && AvFILL(av) != 2)
	    croak("bad object passed to Tcl::Var::STORE");
	sv = *av_fetch(av, 0, FALSE);
	if (sv_isa(sv, "Tcl"))
	{
	    IV tmp = SvIV((SV *) SvRV(sv));
	    interp = (Tcl) tmp;
	}
	else
	    croak("bad object passed to Tcl::Var::STORE");
	if (AvFILL(av) == 2)
	    flags = (int) SvIV(*av_fetch(av, 2, FALSE));
	varname1 = SvPV_nolen(*av_fetch(av, 1, FALSE));
	/*
	 * hash stores have key str1 and value str2
	 * scalar ones just use value str1
	 */
	if (str2)
	    (void) Tcl_SetVar2(interp, varname1, str1, str2, flags);
	else
	    (void) Tcl_SetVar(interp, varname1, str1, flags);
