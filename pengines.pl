:- encoding(utf8).
/*  Part of SWI-Prolog

    Author:        Torbjörn Lager and Jan Wielemaker
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2014, Torbjörn Lager,
			 VU University Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/

:- module(pengines,
	  [ pengine_create/1,			% +Options
            pengine_ask/3,			% +Pengine, :Query, +Options
            pengine_next/2,			% +Pengine. +Options
            pengine_stop/2,			% +Pengine. +Options
            pengine_event/2,			% -Event, +Options
            pengine_input/2,			% +Prompt, -Term
            pengine_output/1,			% +Term
            pengine_respond/3,			% +Pengine, +Input, +Options
            pengine_debug/2,			% +Format, +Args
            pengine_self/1,			% -Pengine
            pengine_pull_response/2,		% +Pengine, +Options
            pengine_destroy/1,			% +Pengine
            pengine_destroy/2,			% +Pengine, +Options
            pengine_abort/1,			% +Pengine
	    pengine_application/1,              % +Application
	    current_pengine_application/1,      % ?Application
            pengine_property/2,			% ?Pengine, ?Property
            pengine_event_loop/2,		% :Closure, +Options
            pengine_rpc/2,			% +Server, :Goal
            pengine_rpc/3			% +Server, +Goal, +Options
	  ]).

/** <module> Pengines: Web Logic Programming Made Easy

The library(pengines) provides an  infrastructure   for  creating Prolog
engines in a (remote) pengine server  and accessing these engines either
from Prolog or JavaScript.

@author Torbjörn Lager and Jan Wielemaker
*/

:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_open)).
:- use_module(library(http/http_stream)).
:- use_module(library(http/http_wrapper)).
:- use_module(library(http/http_cors)).
:- use_module(library(thread_pool)).
:- use_module(library(uri)).
:- use_module(library(filesex)).
:- use_module(library(time)).
:- use_module(library(lists)).
:- use_module(library(charsio)).
:- use_module(library(apply)).
:- use_module(library(aggregate)).
:- use_module(library(option)).
:- use_module(library(settings)).
:- use_module(library(debug)).
:- use_module(library(error)).
:- use_module(library(sandbox)).
:- use_module(library(modules)).
:- use_module(library(term_to_json)).
:- if(exists_source(library(uuid))).
:- use_module(library(uuid)).
:- endif.


:- meta_predicate
	pengine_create(:),
	pengine_rpc(+, +, :),
	pengine_event_loop(1, +).

:- multifile
	event_to_json/3,		% +Event, -JSON, +Format
	prepare_module/3.		% +Module, +Application, +Options

:- predicate_options(pengine_create/1, 1,
		     [ id(-atom),
		       alias(atom),
		       application(atom),
		       destroy(boolean),
		       server(atom),
		       ask(compound),
		       template(compound),
		       chunk(integer),
		       src_list(list),
		       src_text(any),		% text
		       src_url(atom),
		       src_predicates(list),
		       format(atom)
		     ]).
:- predicate_options(pengine_ask/3, 3,
		     [ template(any),
		       chunk(integer)
		     ]).
:- predicate_options(pengine_next/2, 2,
		     [ pass_to(pengine_send/3, 3)
		     ]).
:- predicate_options(pengine_stop/2, 2,
		     [ pass_to(pengine_send/3, 3)
		     ]).
:- predicate_options(pengine_respond/3, 2,
		     [ pass_to(pengine_send/3, 3)
		     ]).
:- predicate_options(pengine_rpc/3, 3,
		     [ chunk(integer),
		       pass_to(pengine_create/1, 1)
		     ]).
:- predicate_options(pengine_send/3, 3,
		     [ delay(number)
		     ]).
:- predicate_options(pengine_event/2, 2,
		     [ pass_to(thread_get_message/3, 3)
		     ]).
:- predicate_options(pengine_pull_response/2, 2,
		     [ pass_to(http_open/3, 3)
		     ]).
:- predicate_options(pengine_event_loop/2, 2,
		     []).			% not yet implemented

% :- debug(pengine(transition)).
:- debug(pengine(debug)).		% handle pengine_debug in pengine_rpc/3.

goal_expansion(random_delay, Expanded) :-
    (   debugging(pengine(delay))
    ->	Expanded = do_random_delay
    ;	Expanded = true
    ).

do_random_delay :-
    Delay is random(20)/1000,
    sleep(Delay).

:- meta_predicate			% internal meta predicates
	solve(?, 0, +),
	findnsols_no_empty(+, ?, 0, -),
	pengine_event_loop(+, 1, +).

/**  pengine_create(:Options) is det.

    Creates a new pengine. Valid options are:

    * id(-ID)
      ID gets instantiated to the id of the pengine. The id is a complex
      term, its structure will remain undocumented and should not be
      relied on.

    * alias(+Name)
      The pengine is named Name (an atom). A slave pengine (child) can
      subsequently be referred to by this name.

    * application(+Application)
      Application in which the pengine runs.  See pengine_application/1.

    * server(+URL)
      The pengine will run in (and in the Prolog context of) the pengine
      server located at URL.

    * src_list(+List_of_clauses)
      Inject a list of Prolog clauses into the pengine.

    * src_text(+Atom_or_string)
      Inject the clauses specified by a source text into the pengine.

    * src_url(+URL)
      Inject the clauses specified in the file located at URL into the
      pengine.

    * src_predicates(+List)
      Send the local predicates denoted by List to the remote pengine.
      List is a list of predicate indicators.

    * format(+Format)
      Determines the format of event responses. Format is an atom.
      The default format is =prolog=.  In addition, =json= is supported
      and new formats can be added by defining event_to_json/3.  See
      library(pengines_io).

Remaining  options  are  passed  to  http_open/3  (meaningful  only  for
non-local pengines) and thread_create/3. Note   that for thread_create/3
only options changing the stack-sizes can be used. In particular, do not
pass the detached or alias options..

Successful creation of a pengine will return an _event term_ of the
following form:

    * create(ID, Term)
      ID is the id of the pengine that was created.
      Term is not used at the moment.

An error will be returned if the pengine could not be created:

    * error(ID, Term)
      ID is invalid, since no pengine was created.
      Term is the exception's error term.
*/


pengine_create(M:Options0) :-
    translate_local_sources(Options0, Options, M),
    (   select_option(server(BaseURL), Options, RestOptions)
    ->  remote_pengine_create(BaseURL, RestOptions)
    ;   local_pengine_create(Options)
    ).

%%	translate_local_sources(+OptionsIn, -Options, +Module) is det.
%
%	Translate  the  `src_predicates`  and  `src_list`  options  into
%	`src_text`. We need to do that   anyway for remote pengines. For
%	local pengines, we could avoid  this   step,  but  there is very
%	little point in transferring source to a local pengine anyway as
%	local pengines can access any  Prolog   predicate  that you make
%	visible to the application.
%
%	Multiple sources are concatenated  to  end   up  with  a  single
%	src_text option.

translate_local_sources(OptionsIn, Options, Module) :-
    translate_local_sources(OptionsIn, Sources, Options2, Module),
    (	Sources == []
    ->	Options = Options2
    ;	Sources = [Source]
    ->	Options = [src_text(Source)|Options2]
    ;	atomics_to_string(Sources, Source)
    ->	Options = [src_text(Source)|Options2]
    ).

translate_local_sources([], [], [], _).
translate_local_sources([H0|T], [S0|S], Options, M) :-
    nonvar(H0),
    translate_local_source(H0, S0, M), !,
    translate_local_sources(T, S, Options, M).
translate_local_sources([H|T0], S, [H|T], M) :-
    translate_local_sources(T0, S, T, M).

translate_local_source(src_predicates(PIs), Source, M) :-
    must_be(list, PIs),
    with_output_to(string(Source),
		   maplist(M:listing, PIs)).
translate_local_source(src_list(Terms), Source, _) :-
    must_be(list, Terms),
    with_output_to(string(Source),
		   forall(member(Term, Terms),
			  format('~k .', [Term]))).
translate_local_source(src_text(Source), Source, _).


/**  pengine_send(+NameOrID, +Term) is det

Same as pengine_send(NameOrID, Term, []).
*/

pengine_send(Target, Event) :-
    pengine_send(Target, Event, []).


/**  pengine_send(+NameOrID, +Term, +Options) is det

Succeeds immediately and  places  Term  in   the  queue  of  the pengine
NameOrID. Options is a list of options:

   * delay(+Time)
     The actual sending is delayed by Time seconds. Time is an integer
     or a float.

Any remaining options are passed to http_open/3.
*/

pengine_send(Target, Event, Options) :-
    must_be(atom, Target),
    pengine_send2(Target, Event, Options).

pengine_send2(self, Event, Options) :- !,
    thread_self(Queue),
    delay_message(queue(Queue), Event, Options).
pengine_send2(Name, Event, Options) :-
    child(Name, Target), !,
    delay_message(pengine(Target), Event, Options).
pengine_send2(Target, Event, Options) :-
    delay_message(pengine(Target), Event, Options).

delay_message(Target, Event, Options) :-
    option(delay(Delay), Options), !,
    alarm(Delay,
	  send_message(Target, Event, Options),
	  _AlarmID,
	  [remove(true)]).
delay_message(Target, Event, Options) :-
    random_delay,
    send_message(Target, Event, Options).

send_message(queue(Queue), Event, _) :-
    thread_send_message(Queue, pengine_request(Event)).
send_message(pengine(Pengine), Event, Options) :-
    (	pengine_remote(Pengine, Server)
    ->	remote_pengine_send(Server, Pengine, Event, Options)
    ;	pengine_thread(Pengine, Thread)
    ->	thread_send_message(Thread, pengine_request(Event))
    ;	existence_error(pengine, Pengine)
    ).

%%	pengine_request(-Request) is det.
%
%	To be used by a  pengine  to   wait  for  the next request. Such
%	messages are placed in the queue by pengine_send/2.

pengine_request(Request) :-
    pengine_self(Self),
    get_pengine_application(Self, Application),
    setting(Application:idle_limit, IdleLimit),
    thread_self(Me),
    (	thread_get_message(Me, pengine_request(Request), [timeout(IdleLimit)])
    ->	true
    ;	Request = destroy
    ).


%%	pengine_reply(+Event) is det.
%%	pengine_reply(+Queue, +Event) is det.
%
%	Reply Event to the parent of the   current  Pengine or the given
%	Queue.  Such  events  are  read   by    the   other   side  with
%	pengine_event/1.

pengine_reply(Event) :-
    nb_getval(pengine_parent, Queue),
    pengine_reply(Queue, Event).

pengine_reply(Queue, Event0) :-
    wrap_first_answer(Event0, Event),
    random_delay,
    debug(pengine(event), 'Reply to ~p: ~p', [Queue, Event]),
    arg(1, Event, ID),
    thread_send_message(Queue, pengine_event(ID, Event)).

wrap_first_answer(Event0, CreateEvent) :-
    retract(wrap_first_answer_in_create_event(CreateEvent,
					      [answer(Event0)])), !.
wrap_first_answer(Event, Event).



/** pengine_ask(+NameOrID, @Query, +Options) is det

Asks pengine NameOrID a query Query.

Options is a list of options:

    * template(+Template)
      Template is a variable (or a term containing variables) shared
      with the query. By default, the template is identical to the
      query.

    * chunk(+Integer)
      Retrieve solutions in chunks of Integer rather than one by one. 1
      means no chunking (default). Other integers indicate the maximum
      number of solutions to retrieve in one chunk.

Any remaining options are passed to pengine_send/3.

Note that the predicate pengine_ask/3 is deterministic, even for queries
that have more than one solution. Also,  the variables in Query will not
be bound. Instead, results will  be  returned   in  the  form  of _event
terms_.

    * success(ID, Terms, More)
      ID is the id of the pengine that succeeded in solving the query.
      Terms is a list holding instantiations of `Template`. More is
      either `true` or `false`, indicating whether we can expect the
      pengine to be able to return more solutions or not, would we call
      pengine_next/2.

    * failure(ID)
      ID is the id of the pengine that failed for lack of a solutions.

    * error(ID, Term)
      ID is the id of the pengine throwing the exception.
      Term is the exception's error term.

    * output(ID, Term)
      ID is the id of a pengine running the query that called
      pengine_output/1. Term is the term that was passed in the first
      argument of pengine_output/1 when it was called.

    * prompt(ID, Term)
      ID is the id of the pengine that called pengine_input/2 and Term is
      the prompt.

Defined in terms of pengine_send/3, like so:

==
pengine_ask(ID, Query, Options) :-
    partition(pengine_ask_option, Options, AskOptions, SendOptions),
    pengine_send(ID, ask(Query, AskOptions), SendOptions).
==
*/

pengine_ask(ID, Query, Options) :-
    partition(pengine_ask_option, Options, AskOptions, SendOptions),
    pengine_send(ID, ask(Query, AskOptions), SendOptions).


pengine_ask_option(template(_)).
pengine_ask_option(chunk(_)).


/** pengine_next(+NameOrID, +Options) is det

Asks pengine NameOrID for the next solution to a query started by
pengine_ask/3. Options are passed to pengine_send/3.

Here too, results will be returned in the form of _event terms_.

    * success(ID, Terms, More)
      ID is the id of the pengine that succeeded in finding yet another
      solution to the query. Terms is a list holding instantiations of
      `Template`. More is either `true` or `false`, indicating whether
      we can expect the pengine to be able to return more solutions or
      not, would we call pengine_next/2.

    * failure(ID)
      ID is the id of the pengine that failed for lack of more solutions.

    * error(ID, Term)
      ID is the id of the pengine throwing the exception.
      Term is the exception's error term.

    * output(ID, Term)
      ID is the id of a pengine running the query that called
      pengine_output/1. Term is the term that was passed in the first
      argument of pengine_output/1 when it was called.

    * prompt(ID, Term)
      ID is the id of the pengine that called pengine_input/2 and Term
      is the prompt.

Defined in terms of pengine_send/3, as follows:

==
pengine_next(ID, Options) :-
    pengine_send(ID, next, Options).
==

*/

pengine_next(ID, Options) :- pengine_send(ID, next, Options).


/** pengine_stop(+NameOrID, +Options) is det

Tells pengine NameOrID to stop looking  for   more  solutions to a query
started by pengine_ask/3. Options are passed to pengine_send/3.

Defined in terms of pengine_send/3, like so:

==
pengine_stop(ID, Options) :-
    pengine_send(ID, stop, Options).
==
*/

pengine_stop(ID, Options) :- pengine_send(ID, stop, Options).


/** pengine_abort(+NameOrID) is det

Aborts the running query. The pengine goes   back  to state `2', waiting
for new queries.

@see pengine_destroy/1.
*/

pengine_abort(Name) :-
    (	child(Name, Pengine)
    ->	true
    ;	Pengine = Name
    ),
    (	pengine_remote(Pengine, Server)
    ->	remote_pengine_abort(Server, Pengine, [])
    ;	pengine_thread(Pengine, Thread),
	catch(thread_signal(Thread, throw(abort_query)), _, true)
    ).


/** pengine_destroy(+NameOrID) is det.
    pengine_destroy(+NameOrID, +Options) is det.

Destroys the pengine NameOrID.  With the option force(true), the pengine
is killed using abort/0 and pengine_destroy/2 succeeds.

@tbd	Should abort the pengine if it is running a query.
*/

pengine_destroy(ID) :-
    pengine_destroy(ID, []).

pengine_destroy(Name, Options) :-
    (	child(Name, ID)
    ->	true
    ;	ID = Name
    ),
    option(force(true), Options), !,
    (	pengine_thread(ID, Thread),
	catch(thread_signal(Thread, abort),
	      error(existence_error(thread, _), _), fail)
    ->	thread_join(Thread, _)			% cannot detach because that
    ;	true					% will result in a warning
    ).
pengine_destroy(ID, _) :-
    catch(pengine_send(ID, destroy),
	  error(existence_error(pengine, ID), _),
	  retractall(child(_,ID))).


/*================= pengines administration =======================
*/

%%	current_pengine(?Id, ?Parent, ?Location)
%
%	Dynamic predicate that registers our known pengines.  Id is
%	an atomic unique datatype.  Parent is the id of our parent
%	pengine.  Location is one of
%
%	  - thread(ThreadId)
%	  - remote(URL)

:- dynamic
	current_pengine/6,		% Id, ParentId, Thread, URL, App, Destroy
	pengine_queue/4,		% Pengine, Queue, TimeOut, Time
	output_queue/3.			% Id, Queue, Time
:- volatile
	current_pengine/6,
	pengine_queue/4,
	output_queue/3.

:- thread_local
	child/2.			% ?Name, ?Child

%%	pengine_register_local(+Id, +Thread, +Queue, +URL, +App, +Destroy) is det.
%%	pengine_register_remote(+Id, +URL, +Queue, +App, +Destroy) is det.
%%	pengine_unregister(+Id) is det.

pengine_register_local(Id, Thread, Queue, URL, Application, Destroy) :-
    asserta(current_pengine(Id, Queue, Thread, URL, Application, Destroy)).

pengine_register_remote(Id, URL, Application, Destroy) :-
    thread_self(Queue),
    asserta(current_pengine(Id, Queue, 0, URL, Application, Destroy)).

%%	pengine_unregister(+Id)
%
%	Called by the pengine thread  destruction.   If  we are a remote
%	pengine thread, our URL  equals  =http=   and  the  queue is the
%	message queue used to send events to the HTTP workers.

pengine_unregister(Id) :-
    thread_self(Me),
    (	current_pengine(Id, Queue, Me, http, _, _)
    ->	with_mutex(pengine, sync_delay_destroy_queue(Id, Queue))
    ;	true
    ),
    retractall(current_pengine(Id, _, Me, _, _, _)).

pengine_unregister_remote(Id) :-
    retractall(current_pengine(Id, _Parent, 0, _, _, _)).

pengine_self(Id) :-
    thread_self(Thread),
    current_pengine(Id, _Parent, Thread, _URL, _Application, _Destroy).

pengine_parent(Parent) :-
    nb_getval(pengine_parent, Parent).

http_pengine_parent(Pengine, Parent) :-
    current_pengine(Pengine, Parent, Thread, _URL, _Application, _Destroy),
    Thread \== 0, !.

pengine_thread(Pengine, Thread) :-
    current_pengine(Pengine, _Parent, Thread, _URL, _Application, _Destroy),
    Thread \== 0, !.

pengine_remote(Pengine, URL) :-
    current_pengine(Pengine, _Parent, 0, URL, _Application, _Destroy).

get_pengine_application(Pengine, Application) :-
    current_pengine(Pengine, _Parent, _, _URL, Application, _Destroy), !.

get_pengine_module(Pengine, Pengine).

:- if(current_predicate(uuid/1)).
pengine_uuid(Id) :-
    uuid(Id, [version(4)]).		% Version 4 is random.
:- else.
:- use_module(library(random)).
pengine_uuid(Id) :-
    Max is 1<<128,
    random_between(0, Max, Num),
    atom_number(Id, Num).
:- endif.

/** pengine_application(+Application) is det.

Directive that must be used to declarate  a module a pengine application
module. The module may not  be  associated   to  any  file.  The default
application is =pengine_sandbox=.  The  example   below  creates  a  new
application =address_book= and imports the  API   defined  in the module
file =adress_book_api.pl= into the application.

  ==
  :- pengine_application(address_book).
  :- use_module(address_book:adress_book_api).
  ==
*/

pengine_application(Application) :-
    throw(error(context_error(nodirective,
                             pengine_application(Application)), _)).

:- multifile
    system:term_expansion/2,
    current_application/1.

%%	current_pengine_application(?Application) is nondet.
%
%	True when Application is a currently defined application.
%
%	@see pengine_application/1

current_pengine_application(Application) :-
    current_application(Application).


% Default settings for all applications

:- setting(thread_pool_size, integer, 100,
	   'Maximum number of pengines this application can run.').
:- setting(thread_pool_stacks, list(compound), [],
	   'Maximum stack sizes for pengines this application can run.').
:- setting(slave_limit, integer, 3,
	   'Maximum number of slave pengines a master pengine can create.').
:- setting(time_limit, number, 300,
	   'Maximum time to wait for output').
:- setting(idle_limit, number, 300,
	   'Pengine auto-destroys when idle for this time').
:- setting(allow_from, list(atom), [*],
	   'IP addresses from which remotes are allowed to connect').
:- setting(deny_from, list(atom), [],
	   'IP addresses from which remotes are NOT allowed to connect').


system:term_expansion((:- pengine_application(Application)), Expanded) :-
    must_be(atom, Application),
    (   module_property(Application, file(_))
    ->  permission_error(create, pengine_application, Application)
    ;   true
    ),
    expand_term((:- setting(Application:thread_pool_size, integer,
			    setting(pengines:thread_pool_size),
			    'Maximum number of pengines this \c
			    application can run.')),
		ThreadPoolSizeSetting),
    expand_term((:- setting(Application:thread_pool_stacks, list(compound),
			    setting(pengines:thread_pool_stacks),
			    'Maximum stack sizes for pengines \c
			    this application can run.')),
		ThreadPoolStacksSetting),
    expand_term((:- setting(Application:slave_limit, integer,
			    setting(pengines:slave_limit),
			    'Maximum number of local slave pengines \c
			    a master pengine can create.')),
		SlaveLimitSetting),
    expand_term((:- setting(Application:time_limit, number,
			    setting(pengines:time_limit),
			    'Maximum time to wait for output')),
		TimeLimitSetting),
    expand_term((:- setting(Application:idle_limit, number,
			    setting(pengines:idle_limit),
			    'Pengine auto-destroys when idle for this time')),
		IdleLimitSetting),
    expand_term((:- setting(Application:allow_from, list(atom),
			    setting(pengines:allow_from),
			    'IP addresses from which remotes are allowed \c
			    to connect')),
		AllowFromSetting),
    expand_term((:- setting(Application:deny_from, list(atom),
			    setting(pengines:deny_from),
			    'IP addresses from which remotes are NOT \c
			    allowed to connect')),
		DenyFromSetting),
    flatten([ pengines:current_application(Application),
	      ThreadPoolSizeSetting,
	      ThreadPoolStacksSetting,
	      SlaveLimitSetting,
	      TimeLimitSetting,
	      IdleLimitSetting,
	      AllowFromSetting,
	      DenyFromSetting
	    ], Expanded).

% Register default application

:- pengine_application(pengine_sandbox).


/** pengine_property(?Pengine, ?Property) is nondet.

True when Property is a property of   the  given Pengine. Enumerates all
pengines  that  are  known  to  the   calling  Prolog  process.  Defined
properties are:

  * self(ID)
    Identifier of the pengine.  This is the same as the first argument,
    and can be used to enumerate all known pengines.
  * alias(Name)
    Name is the alias name of the pengine, as provided through the
    `alias` option when creating the pengine.
  * thread(Thread)
    If the pengine is a local pengine, Thread is the Prolog thread
    identifier of the pengine.
  * remote(Server)
    If the pengine is remote, the URL of the server.
  * application(Application)
    Pengine runs the given application
  * module(Module)
    Temporary module used for running the Pengine.
  * destroy(Destroy)
    Destroy is =true= if the pengines is destroyed automatically
    after completing the query.
  * parent(Queue)
    Message queue to which the (local) pengine reports.
*/


pengine_property(Id, Prop) :-
    nonvar(Id), nonvar(Prop),
    pengine_property2(Id, Prop), !.
pengine_property(Id, Prop) :-
    pengine_property2(Id, Prop).

pengine_property2(Id, self(Id)) :-
    current_pengine(Id, _Parent, _Thread, _URL, _Application, _Destroy).
pengine_property2(Id, module(Id)) :-
    current_pengine(Id, _Parent, _Thread, _URL, _Application, _Destroy).
pengine_property2(Id, alias(Alias)) :-
    child(Alias, Id),
    Alias \== Id.
pengine_property2(Id, thread(Thread)) :-
    current_pengine(Id, _Parent, Thread, _URL, _Application, _Destroy),
    Thread \== 0.
pengine_property2(Id, remote(Server)) :-
    current_pengine(Id, _Parent, 0, Server, _Application, _Destroy).
pengine_property2(Id, application(Application)) :-
    current_pengine(Id, _Parent, _Thread, _Server, Application, _Destroy).
pengine_property2(Id, destroy(Destroy)) :-
    current_pengine(Id, _Parent, _Thread, _Server, _Application, Destroy).
pengine_property2(Id, parent(Parent)) :-
    current_pengine(Id, Parent, _Thread, _URL, _Application, _Destroy).

/** pengine_output(+Term) is det

Sends Term to the parent pengine or thread.
*/

pengine_output(Term) :-
    pengine_self(Me),
    pengine_reply(output(Me, Term)).


/** pengine_debug(+Format, +Args) is det

Create a message using format/3 from Format   and  Args and send this to
the    client.    The    default    JavaScript    client    will    call
=|console.log(Message)|=  if  there  is   a    console.   The  predicate
pengine_rpc/3 calls debug(pengine(debug), '~w',   [Message]).  The debug
topic pengine(debug) is enabled by default.

@see debug/1 and nodebug/1 for controlling the pengine(debug) topic
@see format/2 for format specifications
*/

pengine_debug(Format, Args) :-
    pengine_parent(Queue),
    pengine_self(Self),
    catch(safe_goal(format(atom(_), Format, Args)), E, true),
    (	var(E)
    ->	format(atom(Message), Format, Args)
    ;	message_to_string(E, Message)
    ),
    thread_send_message(Queue, debug(Self, Message)).


/*================= Local pengine =======================
*/

%%	local_pengine_create(+Options)
%
%	Creates  a  local   Pengine,   which    is   a   thread  running
%	pengine_main/2.  It maintains two predicates:
%
%	  - The global dynamic predicate id/2 relates Pengines to their
%	    childs.
%	  - The local predicate id/2 maps named childs to their ids.

local_pengine_create(Options) :-
    thread_self(Self),
    option(application(Application), Options, pengine_sandbox),
    create(Self, Child, Options, local, Application),
    option(alias(Name), Options, Child),
    assert(child(Name, Child)).


%%	thread_pool:create_pool(+Application) is det.
%
%	On demand creation of a thread pool for a pengine application.

thread_pool:create_pool(Application) :-
    current_application(Application),
    setting(Application:thread_pool_size, Size),
    setting(Application:thread_pool_stacks, Stacks),
    thread_pool_create(Application, Size, Stacks).

%%	create(+Queue, -Child, +Options, +URL, +Application) is det.
%
%	Create a new pengine thread.
%
%	@arg Queue is the queue (or thread handle) to report to
%	@arg Child is the identifier of the created pengine.
%	@arg URL is one of =local= or =http=

create(Queue, Child, Options, URL, Application) :-
    (	nonvar(Child)
    ->	true
    ;	pengine_uuid(Child)
    ),
    catch(create0(Queue, Child, Options, URL, Application),
	  Error,
	  create_error(Queue, Child, Error)).

create_error(Queue, Child, Error) :-
    pengine_reply(Queue, error(Child, Error)).

create0(Queue, Child, Options, URL, Application) :-
    (  current_application(Application)
    -> true
    ;  existence_error(pengine_application, Application)
    ),
    (	URL \== http			% pengine is _not_ a child of the
					% HTTP server thread
    ->	aggregate_all(count, child(_,_), Count),
	setting(Application:slave_limit, Max),
	(   Count >= Max
	->  throw(error(resource_error(max_pengines), _))
	;   true
	)
    ;	true
    ),
    partition(pengine_create_option, Options, PengineOptions, RestOptions),
    thread_create_in_pool(
	Application,
        pengine_main(Queue, PengineOptions, Application), ChildThread,
        [ at_exit(pengine_done)
        | RestOptions
	]),
    option(destroy(Destroy), PengineOptions, true),
    pengine_register_local(Child, ChildThread, Queue, URL, Application, Destroy),
    thread_send_message(ChildThread, pengine_registered(Child)),
    (   option(id(Id), Options)
    ->  Id = Child
    ;   true
    ).

pengine_create_option(src_text(_)).
pengine_create_option(src_url(_)).
pengine_create_option(application(_)).
pengine_create_option(destroy(_)).
pengine_create_option(ask(_)).
pengine_create_option(template(_)).
pengine_create_option(chunk(_)).
pengine_create_option(alias(_)).


%%	pengine_done is det.
%
%	Called  from  the  pengine  thread  =at_exit=  option.  Destroys
%	_child_ pengines using pengine_destroy/1.

:- public
	pengine_done/0.

pengine_done :-
    forall(child(_Name, Child),
	   pengine_destroy(Child)),
    pengine_self(Id),
    pengine_unregister(Id).


%%	pengine_main(+Parent, +Options, +Application)
%
%	Run a pengine main loop. First acknowledges its creation and run
%	pengine_main_loop/1.

:- thread_local wrap_first_answer_in_create_event/2.

:- meta_predicate
	pengine_prepare_source(:, +).

pengine_main(Parent, Options, Application) :-
    fix_streams,
    thread_get_message(pengine_registered(Self)),
    nb_setval(pengine_parent, Parent),
    catch(in_temporary_module(
	      Self,
	      pengine_prepare_source(Application, Options),
	      pengine_create_and_loop(Self, Application, Options)),
	  prepare_source_failed,
	  pengine_terminate(Self)).

pengine_create_and_loop(Self, Application, Options) :-
    setting(Application:slave_limit, SlaveLimit),
    CreateEvent = create(Self, [slave_limit(SlaveLimit)|Extra]),
    (   option(ask(Query), Options)
    ->  asserta(wrap_first_answer_in_create_event(CreateEvent, Extra)),
	option(template(Template), Options, Query),
	option(chunk(Chunk), Options, 1),
	pengine_ask(Self, Query, [template(Template), chunk(Chunk)])
    ;   Extra = [],
	pengine_reply(CreateEvent)
    ),
    pengine_main_loop(Self).


%%	fix_streams is det.
%
%	If we are a pengine that is   created  from a web server thread,
%	the current output points to a CGI stream.

fix_streams :-
	fix_stream(current_output).

fix_stream(Name) :-
	is_cgi_stream(Name), !,
	debug(pengine(stream), '~w is a CGI stream!', [Name]),
	set_stream(user_output, alias(Name)).
fix_stream(_).

%%	pengine_prepare_source(:Application, +Options) is det.
%
%	Load the source into the pengine's module.
%
%	@throws =prepare_source_failed= if it failed to prepare the
%		sources.

pengine_prepare_source(Module:Application, Options) :-
    add_import_module(Module, Application, start),
    ignore(prepare_module(Module, Application, Options)),
    catch(maplist(process_create_option(Module), Options), Error, true),
    (	var(Error)
    ->	true
    ;	send_error(Error),
	throw(prepare_source_failed)
    ).

process_create_option(Application, src_text(Text)) :- !,
    pengine_src_text(Text, Application).
process_create_option(Application, src_url(URL)) :- !,
    pengine_src_url(URL, Application).
process_create_option(_, _).


%%	prepare_module(+Module, +Application, +Options) is semidet.
%
%	Hook, called to initialize  the   temporary  private module that
%	provides the working context of a pengine. This hook is executed
%	by the pengine's thread.  Preparing the source consists of three
%	steps:
%
%	  1. Add Application as (first) default import module for Module
%	  2. Call this hook
%	  3. Compile the source provided by the the `src_text` and
%	     `src_url` options
%
%	@arg	Module is a new temporary module (see
%		in_temporary_module/3) that may be (further) prepared
%		by this hook.
%	@arg	Application (also a module) associated to the pengine.
%	@arg	Options is passed from the environment and should
%		(currently) be ignored.


pengine_main_loop(ID) :-
    catch(guarded_main_loop(ID), abort_query,
	  ( debug(pengine(abort), 'Aborting ~p', [ID]),
	    destroy_or_continue(abort(ID))
	  )).


%%	guarded_main_loop(+Pengine) is det.
%
%	Executes state `2' of  the  pengine,   where  it  waits  for two
%	events:
%
%	  - destroy
%	  Terminate the pengine
%	  - ask(:Goal, +Options)
%	  Solve Goal.

guarded_main_loop(ID) :-
    pengine_request(Request),
    (   Request = destroy
    ->  debug(pengine(transition), '~q: 2 = ~q => 1', [ID, destroy]),
	pengine_terminate(ID)
    ;   Request = ask(Goal, Options)
    ->  debug(pengine(transition), '~q: 2 = ~q => 3', [ID, ask(Goal)]),
        ask(ID, Goal, Options)
    ;   debug(pengine(transition), '~q: 2 = ~q => 2', [ID, protocol_error]),
        pengine_reply(error(ID, error(protocol_error, _))),
        guarded_main_loop(ID)
    ).


pengine_terminate(ID) :-
    pengine_reply(destroy(ID)),
    thread_self(Me),		% Make the thread silently disappear
    thread_detach(Me).


%%	solve(+Template, :Goal, +ID) is det.
%
%	Solve Goal. Note that because we can ask for a new goal in state
%	`6', we must provide for an ancesteral cut (prolog_cut_to/1). We
%	need to be sure to  have  a   choice  point  before  we can call
%	prolog_current_choice/1. This is the reason   why this predicate
%	has two clauses.

solve(Template, Goal, ID) :-
    prolog_current_choice(Choice),
    (   call_cleanup(catch(Goal, Error, true), Det=true),
        (   var(Error)
        ->  (   var(Det)
            ->  pengine_reply(success(ID, Template, true)),
                more_solutions(ID, Choice)
            ;   !,			% commit
		destroy_or_continue(success(ID, Template, false))
            )
        ;   !,				% commit
	    (	Error == abort_query
	    ->	throw(Error)
	    ;	destroy_or_continue(error(ID, Error))
	    )
        )
    ;   !,				% commit
	destroy_or_continue(failure(ID))
    ).
solve(_, _, _).				% leave a choice point


destroy_or_continue(Event) :-
    arg(1, Event, ID),
    (	pengine_property(ID, destroy(true))
    ->	thread_self(Me),
	thread_detach(Me),
        pengine_reply(destroy(ID, Event))
    ;   pengine_reply(Event),
	garbage_collect,		% minimise our footprint
	trim_stacks,
	guarded_main_loop(ID)
    ).

%%	more_solutions(+Pengine, +Choice)
%
%	Called after a solution was found while  there can be more. This
%	is state `6' of the state machine. It processes these events:
%
%	  * stop
%	  Go back via state `7' to state `2' (guarded_main_loop/1)
%	  * next
%	  Fail.  This causes solve/3 to backtrack on the goal asked.
%	  * ask(Goal, Options)
%	  Ask another goal.  Note that we must commit the choice point
%	  of the previous goal asked for.

more_solutions(ID, Choice) :-
    pengine_request(Event),
    more_solutions(Event, ID, Choice).

more_solutions(stop, ID, _Choice) :- !,
    debug(pengine(transition), '~q: 6 = ~q => 7', [ID, stop]),
    destroy_or_continue(stop(ID)).
more_solutions(next, ID, _Choice) :- !,
    debug(pengine(transition), '~q: 6 = ~q => 3', [ID, next]),
    fail.
more_solutions(ask(Goal, Options), ID, Choice) :- !,
    debug(pengine(transition), '~q: 6 = ~q => 3', [ID, ask(Goal)]),
    prolog_cut_to(Choice),
    ask(ID, Goal, Options).
more_solutions(destroy, ID, _Choice) :- !,
    debug(pengine(transition), '~q: 6 = ~q => 1', [ID, destroy]),
    pengine_terminate(ID).
more_solutions(Event, ID, Choice) :-
    debug(pengine(transition), '~q: 6 = ~q => 6', [ID, protocol_error(Event)]),
    pengine_reply(error(ID, error(protocol_error, _))),
    more_solutions(ID, Choice).

%%	ask(+Pengine, :Goal, +Options)
%
%	Migrate from state `2' to `3'.  This predicate validates that it
%	is safe to call Goal using safe_goal/1 and then calls solve/3 to
%	prove the goal. It takes care of the chunk(N) option.

ask(ID, Goal, Options) :-
    get_pengine_module(ID, Module),
    expand_goal(Module:Goal, Goal1),
    catch(safe_goal(Goal1), Error, true),
    (   var(Error)
    ->  option(template(Template), Options, Goal),
        option(chunk(N), Options, 1),
        (   N == 1
        ->  solve([Template], Goal1, ID)
        ;   solve(Res, findnsols_no_empty(N, Template, Goal1, Res), ID)
        )
    ;   pengine_reply(error(ID, Error)),
	guarded_main_loop(ID)
    ).

findnsols_no_empty(N, Template, Goal, List) :-
	findnsols(N, Template, Goal, List),
	List \== [].

/** pengine_pull_response(+Pengine, +Options) is det

Pulls a response (an event term) from the  slave Pengine if Pengine is a
remote process, else does nothing at all.
*/

pengine_pull_response(Pengine, Options) :-
    pengine_remote(Pengine, Server), !,
    remote_pengine_pull_response(Server, Pengine, Options).
pengine_pull_response(_ID, _Options).


/** pengine_input(+Prompt, -Term) is det

Sends Prompt to the parent pengine and waits for input. Note that Prompt may be
any term, atomic or complex.
*/

pengine_input(Prompt, Term) :-
    pengine_self(Self),
    nb_getval(pengine_parent, Parent),
    pengine_reply(Parent, prompt(Self, Prompt)),
    pengine_request(input(Term)).


/** pengine_respond(+Pengine, +Input, +Options) is det

Sends a response in the form of the term Input to a slave pengine
that has prompted its master for input.

Defined in terms of pengine_send/3, as follows:

==
pengine_respond(Pengine, Input, Options) :-
    pengine_send(Pengine, input(Input), Options).
==

*/

pengine_respond(Pengine, Input, Options) :-
    pengine_send(Pengine, input(Input), Options).


%%	send_error(+Error) is det.
%
%	Send an error to my parent.   Remove non-readable blobs from the
%	error term first using replace_blobs/2.

send_error(Error) :-
    pengine_self(Self),
    replace_blobs(Error, Error1),
    pengine_reply(error(Self, Error1)).

%%	replace_blobs(Term0, Term) is det.
%
%	Copy Term0 to Term, replacing non-text   blobs. This is required
%	for error messages that may hold   streams  and other handles to
%	non-readable objects.

replace_blobs(Blob, Atom) :-
    blob(Blob, Type), Type \== text, !,
    format(atom(Atom), '~p', [Blob]).
replace_blobs(Term0, Term) :-
    compound(Term0), !,
    compound_name_arguments(Term0, Name, Args0),
    maplist(replace_blobs, Args0, Args),
    compound_name_arguments(Term, Name, Args).
replace_blobs(Term, Term).


/*================= Remote pengines =======================
*/


remote_pengine_create(BaseURL, Options) :-
    partition(pengine_create_option, Options, PengineOptions, RestOptions),
    options_to_dict(PengineOptions, PostData),
    remote_post_rec(BaseURL, create, PostData, Reply, RestOptions),
    arg(1, Reply, ID),
    (	option(id(ID2), Options)
    ->	ID = ID2
    ;	true
    ),
    option(alias(Name), Options, ID),
    assert(child(Name, ID)),
    (	functor(Reply, create, _)	% actually created
    ->	option(application(Application), PengineOptions, pengine_sandbox),
	option(destroy(Destroy), PengineOptions, true),
	pengine_register_remote(ID, BaseURL, Application, Destroy)
    ;	true
    ),
    thread_self(Queue),
    pengine_reply(Queue, Reply).

options_to_dict(Options, Dict) :-
    select_option(ask(Ask), Options, Options1),
    select_option(template(Template), Options1, Options2), !,
    no_numbered_var_in(Ask+Template),
    findall(AskString-TemplateString,
	    ask_template_to_strings(Ask, Template, AskString, TemplateString),
	    [ AskString-TemplateString ]),
    options_to_dict(Options2, Dict0),
    Dict = Dict0.put(_{ask:AskString,template:TemplateString}).
options_to_dict(Options, Dict) :-
    maplist(prolog_option, Options, Options1),
    dict_create(Dict, _, Options1).

no_numbered_var_in(Term) :-
    sub_term(Sub, Term),
    subsumes_term('$VAR'(_), Sub), !,
    domain_error(numbered_vars_free_term, Term).
no_numbered_var_in(_).

ask_template_to_strings(Ask, Template, AskString, TemplateString) :-
    numbervars(Ask+Template, 0, _),
    WOpts = [ numbervars(true), ignore_ops(true), quoted(true) ],
    format(string(AskTemplate), '~W\n~W', [ Ask, WOpts,
					    Template, WOpts
					  ]),
    split_string(AskTemplate, "\n", "", [AskString, TemplateString]).

prolog_option(Option0, Option) :-
    create_option_type(Option0, term), !,
    Option0 =.. [Name,Value],
    format(string(String), '~k', [Value]),
    Option =.. [Name,String].
prolog_option(Option, Option).

create_option_type(ask(_),         term).
create_option_type(template(_),    term).
create_option_type(application(_), atom).

remote_pengine_send(BaseURL, ID, Event, Options) :-
    term_to_atom(Event, EventAtom),
    remote_send_rec(BaseURL, send, [id=ID, event=EventAtom], Reply, Options),
    thread_self(Queue),
    pengine_reply(Queue, Reply).

remote_pengine_pull_response(BaseURL, ID, Options) :-
    remote_send_rec(BaseURL, pull_response, [id=ID], Reply, Options),
    thread_self(Queue),
    pengine_reply(Queue, Reply).

remote_pengine_abort(BaseURL, ID, Options) :-
    remote_send_rec(BaseURL, abort, [id=ID], Reply, Options),
    thread_self(Queue),
    pengine_reply(Queue, Reply).

%%	remote_send_rec(+Server, +Action, +Params, -Reply, +Options)
%
%	Issue a GET request on Server and   unify Reply with the replied
%	term.

remote_send_rec(Server, Action, Params, Reply, Options) :-
    server_url(Server, Action, Params, URL),
    http_open(URL, Stream, Options),	% putting this in setup_call_cleanup/3
    call_cleanup(			% makes it impossible to interrupt.
	read_prolog_reply(Stream, Reply),
	close(Stream)).

remote_post_rec(Server, Action, Data, Reply, Options) :-
    server_url(Server, Action, [], URL),
    http_open(URL, Stream,
	      [ post(json(Data))
	      | Options
	      ]),
    call_cleanup(			% makes it impossible to interrupt.
	read_prolog_reply(Stream, Reply),
	close(Stream)).

read_prolog_reply(In, Reply) :-
    set_stream(In, encoding(utf8)),
    read(In, Reply).

server_url(Server, Action, Params, URL) :-
    uri_components(Server, Components0),
    uri_query_components(Query, Params),
    uri_data(path, Components0, Path0),
    atom_concat('pengine/', Action, PAction),
    directory_file_path(Path0, PAction, Path),
    uri_data(path, Components0, Path, Components),
    uri_data(search, Components, Query),
    uri_components(URL, Components).


/** pengine_event(?EventTerm) is det.
    pengine_event(?EventTerm, +Options) is det.

Examines the pengine's event queue  and   if  necessary blocks execution
until a term that unifies to Term  arrives   in  the queue. After a term
from the queue has been unified to Term,   the  term is deleted from the
queue.

   Valid options are:

   * timeout(+Time)
     Time is a float or integer and specifies the maximum time to wait
     in seconds. If no event has arrived before the time is up EventTerm
     is bound to the atom =timeout=.
   * listen(+Id)
     Only listen to events from the pengine identified by Id.
*/

pengine_event(Event) :-
    pengine_event(Event, []).

pengine_event(Event, Options) :-
    thread_self(Self),
    option(listen(Id), Options, _),
    (   thread_get_message(Self, pengine_event(Id, Event), Options)
    ->  true
    ;   Event = timeout
    ),
    update_remote_destroy(Event).

update_remote_destroy(Event) :-
    pengine_remote(Id, _Server),
    destroy_event(Event), !,
    pengine_unregister_remote(Id).
update_remote_destroy(_).

destroy_event(destroy(_)).
destroy_event(destroy(_,_)).
destroy_event(create(_,Features)) :-
    memberchk(answer(Answer), Features), !,
    nonvar(Answer),
    destroy_event(Answer).


/** pengine_event_loop(:Closure, +Options) is det

Starts an event loop accepting event terms   sent to the current pengine
or thread. For each such  event   E,  calls  ignore(call(Closure, E)). A
closure thus acts as a _handler_  for   the  event. Some events are also
treated specially:

   * create(ID, Term)
     The ID is placed in a list of active pengines.

   * destroy(ID)
     The ID is removed from the list of active pengines. When the last
     pengine ID is removed, the loop terminates.

   * output(ID, Term)
     The predicate pengine_pull_response/2 is called.

Valid options are:

   * autoforward(+To)
     Forwards received event terms to slaves. To is either =all=,
     =all_but_sender= or a Prolog list of NameOrIDs. [not yet
     implemented]

*/

pengine_event_loop(Closure, Options) :-
    child(_,_), !,
    pengine_event(Event),
    (   option(autoforward(all), Options) % TODO: Implement all_but_sender and list of IDs
    ->  forall(child(_,ID), pengine_send(ID, Event))
    ;   true
    ),
    pengine_event_loop(Event, Closure, Options).
pengine_event_loop(_, _).

:- meta_predicate
    pengine_process_event(+, 1, -, +).

pengine_event_loop(Event, Closure, Options) :-
    pengine_process_event(Event, Closure, Continue, Options),
    (	Continue == true
    ->	pengine_event_loop(Closure, Options)
    ;	true
    ).

pengine_process_event(create(ID, T), Closure, Continue, Options) :-
    debug(pengine(transition), '~q: 1 = /~q => 2', [ID, create(T)]),
    (	select(answer(First), T, T1)
    ->	ignore(call(Closure, create(ID, T1))),
	pengine_process_event(First, Closure, Continue, Options)
    ;	ignore(call(Closure, create(ID, T))),
	Continue = true
    ).
pengine_process_event(output(ID, Msg), Closure, true, _Options) :-
    debug(pengine(transition), '~q: 3 = /~q => 4', [ID, output(Msg)]),
    ignore(call(Closure, output(ID, Msg))),
    pengine_pull_response(ID, []).
pengine_process_event(debug(ID, Msg), Closure, true, _Options) :-
    debug(pengine(transition), '~q: 3 = /~q => 4', [ID, debug(Msg)]),
    ignore(call(Closure, debug(ID, Msg))),
    pengine_pull_response(ID, []).
pengine_process_event(prompt(ID, Term), Closure, true, _Options) :-
    debug(pengine(transition), '~q: 3 = /~q => 5', [ID, prompt(Term)]),
    ignore(call(Closure, prompt(ID, Term))).
pengine_process_event(success(ID, Sol, More), Closure, true, _Options) :-
    debug(pengine(transition), '~q: 3 = /~q => 6/2', [ID, success(Sol, More)]),
    ignore(call(Closure, success(ID, Sol, More))).
pengine_process_event(failure(ID), Closure, true, _Options) :-
    debug(pengine(transition), '~q: 3 = /~q => 2', [ID, failure]),
    ignore(call(Closure, failure(ID))).
pengine_process_event(error(ID, Error), Closure, Continue, _Options) :-
    debug(pengine(transition), '~q: 3 = /~q => 2', [ID, error(Error)]),
    (	call(Closure, error(ID, Error))
    ->	Continue = true
    ;	forall(child(_,Child), pengine_destroy(Child)),
	throw(Error)
    ).
pengine_process_event(stop(ID), Closure, true, _Options) :-
    debug(pengine(transition), '~q: 7 = /~q => 2', [ID, stop]),
    ignore(call(Closure, stop(ID))).
pengine_process_event(destroy(ID, Event), Closure, Continue, Options) :-
    pengine_process_event(Event, Closure, _, Options),
    pengine_process_event(destroy(ID), Closure, Continue, Options).
pengine_process_event(destroy(ID), Closure, true, _Options) :-
    retractall(child(_,ID)),
    debug(pengine(transition), '~q: 1 = /~q => 0', [ID, destroy]),
    ignore(call(Closure, destroy(ID))).


/** pengine_rpc(+URL, +Query) is nondet.
    pengine_rpc(+URL, +Query, +Options) is nondet.

Semantically equivalent to the sequence below,  except that the query is
executed in (and in the Prolog context   of) the pengine server referred
to by URL, rather than locally.

  ==
    copy_term(Query, Copy),
    call(Copy),			% executed on server at URL
    Query = Copy.
  ==

Valid options are:

    * chunk(+Integer)
      Can be used to reduce the number of network roundtrips being made.
      See pengine_ask/3.

Remaining  options  (except   the   server    option)   are   passed  to
pengine_create/1.
*/

pengine_rpc(URL, Query) :-
    pengine_rpc(URL, Query, []).

pengine_rpc(URL, Query, M:Options0) :-
    translate_local_sources(Options0, Options, M),
    term_variables(Query, Vars),
    Template =.. [v|Vars],
    State = destroy(true),
    setup_call_catcher_cleanup(
	pengine_create([ ask(Query),
			 template(Template),
			 server(URL),
			 id(Id)
		       | Options
		       ]),
	wait_event(Template, State, [listen(Id)|Options]),
	Why,
	pengine_destroy_and_wait(State, Id, Why)).

pengine_destroy_and_wait(destroy(true), Id, Why) :- !,
    debug(pengine(destroy), 'Destroying RPC because of ~p', [Why]),
    pengine_destroy(Id),
    pengine_event(destroy(Id)),
    retractall(child(_,Id)).
pengine_destroy_and_wait(_, _, Why) :-
    debug(pengine(destroy), 'Not destroying RPC (~p)', [Why]).

wait_event(Template, State, Options) :-
    pengine_event(Event, Options),
    debug(pengine(event), 'Received ~p', [Event]),
    process_event(Event, Template, State, Options).

process_event(create(_ID, Features), Template, State, Options) :-
    memberchk(answer(First), Features),
    process_event(First, Template, State, Options).
process_event(error(_ID, Error), _Template, _, _Options) :-
    throw(Error).
process_event(failure(_ID), _Template, _, _Options) :-
    fail.
process_event(prompt(ID, Prompt), Template, State, Options) :-
    pengine_rpc_prompt(ID, Prompt, Reply),
    pengine_send(ID, input(Reply)),
    wait_event(Template, State, Options).
process_event(output(ID, Term), Template, State, Options) :-
    pengine_rpc_output(ID, Term),
    pengine_pull_response(ID, Options),
    wait_event(Template, State, Options).
process_event(debug(ID, Message), Template, State, Options) :-
    debug(pengine(debug), '~w', [Message]),
    pengine_pull_response(ID, Options),
    wait_event(Template, State, Options).
process_event(success(_ID, Solutions, false), Template, _, _Options) :- !,
    member(Template, Solutions).
process_event(success(ID, Solutions, true), Template, State, Options) :-
    (	member(Template, Solutions)
    ;   pengine_next(ID, Options),
	wait_event(Template, State, Options)
    ).
process_event(destroy(ID, Event), Template, State, Options) :- !,
    retractall(child(_,ID)),
    nb_setarg(1, State, false),
    debug(pengine(destroy), 'State: ~p~n', [State]),
    process_event(Event, Template, State, Options).

pengine_rpc_prompt(ID, Prompt, Term) :-
    prompt(ID, Prompt, Term0), !,
    Term = Term0.
pengine_rpc_prompt(_ID, Prompt, Term) :-
    setup_call_cleanup(
	prompt(Old, Prompt),
	read(Term),
	prompt(_, Old)).

pengine_rpc_output(ID, Term) :-
    output(ID, Term), !.
pengine_rpc_output(_ID, Term) :-
    print(Term).

%%  prompt(+ID, +Prompt, -Term) is semidet.
%
%   Hook to handle pengine_input/2 from the remote pengine. If the hooks
%   fails, pengine_rpc/3 calls read/1 using the current prompt.

:- multifile prompt/3.

%%  output(+ID, +Term) is semidet.
%
%   Hook to handle pengine_output/1 from the remote pengine. If the hook
%   fails, it calls print/1 on Term.

:- multifile output/2.


/*================= HTTP handlers =======================
*/

%   Declare HTTP locations we serve and how.

:- http_handler(root(pengine/create),	     http_pengine_create,	 []).
:- http_handler(root(pengine/send),	     http_pengine_send,		 []).
:- http_handler(root(pengine/pull_response), http_pengine_pull_response, []).
:- http_handler(root(pengine/abort),	     http_pengine_abort,	 []).
:- http_handler(root(pengine/destroy_all),   http_pengine_destroy_all,	 []).

:- http_handler(root(pengine/'pengines.js'),
		http_reply_file(library('http/web/js/pengines.js'), []), []).
:- http_handler(root(pengine/'plterm.css'),
		http_reply_file(library('http/web/css/plterm.css'), []), []).


http_pengine_create(Request) :-
    http_read_json_dict(Request, Dict),
    (	get_dict(format, Dict, FormatString)
    ->	atom_string(Format, FormatString),
	valid_format(Format)
    ;	Format = prolog
    ),
    dict_to_options(Dict, CreateOptions),
    option(application(Application), CreateOptions, pengine_sandbox),
    (	current_application(Application)
    ->  allowed(Request, Application),
	pengine_uuid(Pengine),
	message_queue_create(Queue, [max_size(25)]),
	setting(Application:time_limit, TimeLimit),
	get_time(Now),
	asserta(pengine_queue(Pengine, Queue, TimeLimit, Now)),
	create(Queue, Pengine, CreateOptions, http, Application),
	wait_and_output_result(Pengine, Queue, Format, TimeLimit)
    ;	Error = existence_error(pengine_application, Application),
	pengine_uuid(ID),
        output_result(Format, error(ID, error(Error, _)))
    ).

dict_to_options(Dict, CreateOptions) :-
    dict_pairs(Dict, _, Pairs),
    pairs_create_options(Pairs, CreateOptions).

pairs_create_options([], []).
pairs_create_options(T0, [AskOpt, TemplateOpt|T]) :-
    selectchk(ask-Ask, T0, T1),
    selectchk(template-Template, T1, T2), !,
    format(string(AskTemplate), 't((~s),(~s))', [Ask, Template]),
    term_string(t(Ask1,Template1), AskTemplate),
    AskOpt = ask(Ask1),
    TemplateOpt = template(Template1),
    pairs_create_options(T2, T).
pairs_create_options([N-V0|T0], [Opt|T]) :-
    Opt =.. [N,V],
    pengine_create_option(Opt), !,
    (   create_option_type(Opt, Type)
    ->  (   Type == term
	->  atom_to_term(V0, V, _)
	;   Type == atom
	->  atom_string(V, V0)
	;   assertion(false)
	)
    ;   V = V0
    ),
    pairs_create_options(T0, T).
pairs_create_options([_|T0], T) :-
    pairs_create_options(T0, T).


%%	wait_and_output_result(+Pengine, +Queue, +Format, +TimeLimit)
%
%	Wait for the Pengine's Queue and if  there is a message, send it
%	to the requestor using  output_result/1.   If  Pengine  does not
%	answer within the time specified   by  the setting =time_limit=,
%	Pengine is aborted and the  result is error(time_limit_exceeded,
%	_).

wait_and_output_result(Pengine, Queue, Format, TimeLimit) :-
    (   thread_get_message(Queue, pengine_event(_, Event),
			   [ timeout(TimeLimit)
			   ]),
	debug(pengine(wait), 'Got ~q from ~q', [Event, Queue]),
	destroy_queue(Pengine, Event, Queue)
    ->  output_result(Format, Event)
    ;   output_result(Format, error(Pengine,
				    error(time_limit_exceeded, _))),
        pengine_abort(Pengine)
    ).

%%	destroy_queue(+Pengine, +Event, +Queue) is det.
%
%	Destroy the output queue for Pengine.   We can destroy the queue
%	if it is in _delayed mode_  (see pengine_unregister/1) and empty
%	or if it is in normal mode and   the  event is the final destroy
%	event.
%
%	@tbd	If the client did not request all output, the queue will
%		not be destroyed.  We need some timeout and GC for that.

destroy_queue(ID, _, Queue) :-
    output_queue(ID, Queue, _), !,
    (	thread_peek_message(Queue, _)
    ->	true
    ;	retractall(output_queue(ID, Queue, _)),
	message_queue_destroy(Queue)
    ).
destroy_queue(ID, Event, Queue) :-
    debug(pengine(destroy), 'DESTROY? ~p', [Event]),
    is_destroy_event(Event), !,
    message_queue_property(Queue, size(Waiting)),
    debug(pengine(destroy), 'Destroy ~p (waiting ~D)', [Queue, Waiting]),
    with_mutex(pengine, sync_destroy_queue(ID, Queue)).
destroy_queue(_, _, _).

is_destroy_event(destroy(_)).
is_destroy_event(destroy(_,_)).

%%	sync_destroy_queue(+Pengine, +Queue) is det.
%%	sync_delay_destroy_queue(+Pengine, +Queue) is det.
%
%	Handle destruction of the message queue connecting the HTTP side
%	to the pengine. We cannot delete the queue when the pengine dies
%	because the queue may contain output  events. Termination of the
%	pengine and finishing the  HTTP  exchange   may  happen  in both
%	orders. This means we need handle this using synchronization.
%
%	@tbd	If message queue handles were save, we could check the
%		existence and get rid of output_queue_destroyed/1.  As
%		is, they are small integer references, subject to the
%		ABA issue.
%
%		(*) we exploit the recycling of message queue IDs ...

:- dynamic output_queue_destroyed/1.

sync_destroy_queue(ID, Queue) :-
    (	output_queue(ID, Queue, _)
    ->  true
    ;	thread_peek_message(Queue, pengine_event(_, output(_,_)))
    ->	debug(pengine(destroy), 'Delay destruction of ~p because of output',
	      [Queue]),
        get_time(Now),
	asserta(output_queue(ID, Queue, Now))
    ;	message_queue_destroy(Queue),
	retractall(output_queue_destroyed(Queue)), % (*)
	asserta(output_queue_destroyed(Queue))
    ).

sync_delay_destroy_queue(ID, Queue) :-
    (   retract(output_queue_destroyed(Queue))
    ->  true
    ;   get_time(Now),
	asserta(output_queue(ID, Queue, Now))
    ),
    retractall(pengine_queue(ID, Queue, _, _)).


http_pengine_send(Request) :-
    http_parameters(Request,
		    [ id(ID, [ type(atom) ]),
		      event(EventString, []),
		      format(Format, [default(prolog)])
		    ]),
    get_pengine_module(ID, Module), !,
    catch(( term_string(Event0, EventString,
			[ variable_names(Bindings),
			  module(Module)
			]),
	    fix_bindings(Format, Event0, ID, Bindings, Event1)
	  ),
	  Error,
	  true),
    (	var(Error)
    ->	debug(pengine(event), 'HTTP send: ~p', [Event1]),
	(   pengine_thread(ID, Thread)
	->  pengine_queue(ID, Queue, TimeLimit, _),
	    random_delay,
	    thread_send_message(Thread, pengine_request(Event1)),
	    wait_and_output_result(ID, Queue, Format, TimeLimit)
	;   atom(ID)
	->  output_result(Format, error(ID,error(existence_error(pengine, ID),_)))
	;   http_404([], Request)
	)
    ;	output_result(Format, error(ID, Error))
    ).


%%	fix_bindings(+Format, +EventIn, -Event) is det.
%
%	Generate the template for json(-s) Format  from the variables in
%	the asked Goal. Variables starting  with an underscore, followed
%	by an capital letter are ignored from the template.

fix_bindings(Format,
	     ask(Goal, Options), _ID, Bindings,
	     ask(Goal, NewOptions)) :-
    json_lang(Format), !,
    template(Bindings, Template, Options),
    option(chunk(Paging), Options, 1),
    NewOptions = [template(Template), chunk(Paging)].
fix_bindings(_, Command, _, _, Command).

template(_, Template, Options) :-
    option(template(Template), Options), !.
template(Bindings, Template, _Options) :-
    exclude(anon, Bindings, Bindings1),
    dict_create(Template, json, Bindings1).

anon(Name=_) :-
    sub_atom(Name, 0, _, _, '_'),
    sub_atom(Name, 1, 1, _, Next),
    char_type(Next, prolog_var_start).

%%	json_lang(+Format) is semidet.
%
%	True if Format is a JSON variation.

json_lang(json) :- !.
json_lang(Format) :-
    sub_atom(Format, 0, _, _, 'json-').

valid_format(prolog) :- !.
valid_format(Format) :-
	json_lang(Format), !.
valid_format(Format) :-
	domain_error(pengine_format, Format).

%%	http_pengine_pull_response(+Request)
%
%	HTTP handler for /pengine/pull_response.  Pulls possible pending
%	messages from the pengine.

http_pengine_pull_response(Request) :-
    http_parameters(Request,
            [   id(ID, []),
                format(Format, [default(prolog)])
            ]),
    (	(   pengine_queue(ID, Queue, TimeLimit, _)
	->  true
	;   output_queue(ID, Queue, _),
	    TimeLimit = 0
	)
    ->	wait_and_output_result(ID, Queue, Format, TimeLimit)
    ;	http_404([], Request)
    ).

http_pengine_abort(Request) :-
    http_parameters(Request,
            [   id(ID, []),
                format(Format, [default(prolog)])
            ]),
    (	pengine_thread(ID, _Thread),
	pengine_queue(ID, Queue, TimeLimit, _)
    ->	pengine_abort(ID),
	wait_and_output_result(ID, Queue, Format, TimeLimit)
    ;	http_404([], Request)
    ).

http_pengine_destroy_all(Request) :-
    http_parameters(Request,
		    [ ids(IDsAtom, [])
		    ]),
    atomic_list_concat(IDs, ',', IDsAtom),
    forall(member(ID, IDs),
	   pengine_destroy(ID, [force(true)])),
    reply_json("ok").

%%	output_result(+Format, +EventTerm) is det.
%
%	Formulate an HTTP response from a pengine event term. Format is
%	one of =prolog=, =json= or =json-s=.

output_result(prolog, Event) :- !,
    format('Content-type: text/x-prolog; charset=UTF-8~n~n'),
    write_term(Event,
	       [ quoted(true),
		 ignore_ops(true),
		 fullstop(true),
		 nl(true)
	       ]).
output_result(Lang, Event) :-
    json_lang(Lang), !,
    (	event_term_to_json_data(Event, JSON, Lang)
    ->	cors_enable,
	reply_json(JSON)
    ;	assertion(event_term_to_json_data(Event, _, Lang))
    ).
output_result(Lang, _Event) :-			% FIXME: allow for non-JSON format
    domain_error(pengine_format, Lang).

event_term_to_json_data(Event, JSON, Lang) :-
    event_to_json(Event, JSON, Lang), !.
event_term_to_json_data(success(ID, Bindings0, More),
			json{event:success, id:ID, data:Bindings, more:More},
			json) :- !,
    term_to_json(Bindings0, Bindings).
event_term_to_json_data(create(ID, Features0), JSON, Style) :- !,
    (	select(answer(First0), Features0, Features1)
    ->	event_term_to_json_data(First0, First, Style),
	Features = [answer(First)|Features1]
    ;	Features = Features0
    ),
    dict_create(JSON, json, [event(create), id(ID)|Features]).
event_term_to_json_data(destroy(ID, Event),
			json{event:destroy, id:ID, data:JSON}, Style) :- !,
    event_term_to_json_data(Event, JSON, Style).
event_term_to_json_data(error(ID, ErrorTerm),
			json{event:error, id:ID, data:Message}, _) :- !,
    message_to_string(ErrorTerm, Message).
event_term_to_json_data(EventTerm, json{event:F, id:ID}, _) :-
    functor(EventTerm, F, 1), !,
    arg(1, EventTerm, ID).
event_term_to_json_data(EventTerm, json{event:F, id:ID, data:JSON}, _) :-
    functor(EventTerm, F, 2),
    arg(1, EventTerm, ID),
    arg(2, EventTerm, Data),
    term_to_json(Data, JSON).

%%	event_to_json(+Event, -JSONTerm, +Lang) is semidet.
%
%	Hook that translates a Prlog Pengine event structure into a term
%	suitable   for   reply_json/1,   according   to   the   language
%	specification Lang. This can be used   to massage general Prolog
%	terms, notably assosiated with   `success(ID,  Bindings0, More)`
%	and `output(ID, Term)` into a format  suitable for processing at
%	the client side.

%:- multifile pengines:event_to_json/3.


		 /*******************************
		 *	  ACCESS CONTROL	*
		 *******************************/

%%	allowed(+Request, +Application) is det.
%
%	Check whether the peer is allowed to connect.  Returns a
%	=forbidden= header if contact is not allowed.

allowed(Request, Application) :-
	setting(Application:allow_from, Allow),
	match_peer(Request, Allow),
	setting(Application:deny_from, Deny),
	\+ match_peer(Request, Deny), !.
allowed(Request, _Application) :-
	memberchk(request_uri(Here), Request),
	throw(http_reply(forbidden(Here))).

match_peer(_, Allowed) :-
	memberchk(*, Allowed), !.
match_peer(_, []) :- !, fail.
match_peer(Request, Allowed) :-
	http_peer(Request, Peer),
	debug(pengine(allow), 'Peer: ~q, Allow: ~q', [Peer, Allowed]),
	(   memberchk(Peer, Allowed)
	->  true
	;   member(Pattern, Allowed),
	    match_peer_pattern(Pattern, Peer)
	).

match_peer_pattern(Pattern, Peer) :-
	ip_term(Pattern, IP),
	ip_term(Peer, IP), !.

ip_term(Peer, Pattern) :-
	split_string(Peer, ".", "", PartStrings),
	ip_pattern(PartStrings, Pattern).

ip_pattern([], []).
ip_pattern([*], _) :- !.
ip_pattern([S|T0], [N|T]) :-
	number_string(N, S),
	ip_pattern(T0, T).


		 /*******************************
		 *	  COMPILE SOURCE	*
		 *******************************/

/** pengine_src_text(+SrcText, +Module) is det

Asserts the clauses defined in SrcText in   the  private database of the
current Pengine. This  predicate  processes   the  `src_text'  option of
pengine_create/1.
*/

pengine_src_text(Src, Module) :-
    pengine_self(Self),
    format(atom(ID), 'pengine://~w/src', [Self]),
    setup_call_cleanup(
	open_chars_stream(Src, Stream),
	load_files(Module:ID,
		   [ stream(Stream),
		     module(Module),
		     sandboxed(true),
		     silent(true)
		   ]),
	close(Stream)).

/** pengine_src_url(+URL, +Module) is det

Asserts the clauses defined in  URL  in   the  private  database  of the
current Pengine. This  predicate  processes   the  `src_url'  option  of
pengine_create/1.
*/

pengine_src_url(URL, Module) :-
    pengine_self(Self),
    uri_encoded(path, URL, Path),
    format(atom(ID), 'pengine://~w/url/~w', [Self, Path]),
    setup_call_cleanup(
	http_open(URL, Stream, []),
	load_files(Module:ID,
		   [ stream(Stream),
		     module(Module),
		     sandboxed(true),
		     silent(true)
		   ]),
	close(Stream)).


		 /*******************************
		 *	  SANDBOX SUPPORT	*
		 *******************************/

:- multifile
	sandbox:safe_primitive/1,		% Goal
	sandbox:safe_meta/2.			% Goal, Calls

%%	sandbox:safe_primitive(+Goal) is semidet.
%
%	Declare the core pengine operations as   safe. If we are talking
%	about  local  pengines,  their  safety   is  guaranteed  by  the
%	sandboxing done for all pengines.
%
%	@tbd	If at some point we allow for `unsafe' pengines, we must
%		reconsider this.

sandbox:safe_primitive(pengines:pengine_create(_)).
sandbox:safe_primitive(pengines:pengine_destroy(_,_)).
sandbox:safe_primitive(pengines:pengine_event(_, _)).
sandbox:safe_primitive(pengines:pengine_send(_, _, _)).
sandbox:safe_primitive(pengines:pengine_input(_, _)).
sandbox:safe_primitive(pengines:pengine_output(_)).
sandbox:safe_primitive(pengines:pengine_debug(_,_)).
sandbox:safe_primitive(pengines:pengine_rpc(_, _, _)).
sandbox:safe_primitive(pengines:pengine_ask(_, _, _)).
sandbox:safe_primitive(pengines:pengine_pull_response(_,_)).

sandbox:safe_meta(pengines:pengine_event_loop(_,Closure,_,_), [Closure1]) :-
	extend_goal(Closure, [_], Closure1).

extend_goal(Var, _, _) :-
	var(Var), !,
	instantiation_error(Var).
extend_goal(M:Term0, Extra, M:Term) :-
	extend_goal(Term0, Extra, Term).
extend_goal(Atom, Extra, Goal) :-
	atom(Atom), !,
	Goal =.. [Atom|Extra].
extend_goal(Compound, Extra, Goal) :-
	compound(Compound), !,
	compound_name_arguments(Compound, Name, Args0),
	append(Args0, Extra, Args),
	compound_name_arguments(Goal, Name, Args).
