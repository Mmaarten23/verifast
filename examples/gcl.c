/*

An interpreter for a minimalist Garbage-Collected Language
including a basic mark-sweep garbage collector.

Reads expressions from standard input and executes them.

Syntax:

EXPR ::= ATOM               variable lookup
       | (EXPR EXPR)        function application
       | (fun (PARAM BODY)) lambda expression
       | (quote EXPR)       evaluates to EXPR itself

Currently, there is just one built-in function: 'print_atom'.

Examples:

    (print_atom (quote Hello_world!))
 => Hello_world!

    ((fun (iter (iter iter)))
     (fun (iter ((fun (v (iter iter))) (print_atom (quote Hello))))))
 => HelloHelloHelloHello...

To compile (with MSVC):

    cl gcl.c tokenizer.c stringBuffers.c

Performs tail call optimization. Also: does not use the C stack
(i.e. the C program performs no recursion), so recursion depth is
limited only by available memory and no C stack overflows can
happen.

Memory safety of the interpreter has been verified using VeriFast. It follows
that it is relatively safe to run untrusted code with this interpreter.

This version uses Schorr-Waite for garbage collection. For a slightly simpler
garbage collector, see gcl0.c.

TODO:
- Remove assume statements; enable arithmetic overflow checking
- Performance enhancements:
  - Allocate the nodes of the roots list on the stack (as opposed to malloc'ing them)
  - Avoid some roots by reasoning about reachability
  - ...
- ...

*/


#include <stdlib.h>
#include <stdio.h>
#include "stringBuffers.h"
#include "tokenizer.h"
#include "assert.h"

void error(char *msg)
    //@ requires [?f]string(msg, _);
    //@ ensures false;
{
    puts(msg);
    abort();
}

struct stack {
    void *head;
    struct stack *tail;
};

/*@

predicate stack(struct stack *stack; list<void *> elems) =
    stack == 0 ?
        elems == nil
    :
        stack->head |-> ?head &*&
        stack->tail |-> ?tail &*&
        malloc_block_stack(stack) &*&
        stack(tail, ?elems0) &*&
        elems == cons(head, elems0);

@*/

void stack_push(struct stack **stack, void *value)
    //@ requires pointer(stack, ?s) &*& stack(s, ?elems);
    //@ ensures pointer(stack, ?s1) &*& stack(s1, cons(value, elems));
{
    struct stack *newStack = malloc(sizeof(struct stack));
    if (newStack == 0) abort();
    newStack->head = value;
    newStack->tail = *stack;
    *stack = newStack;
}

void *stack_pop(struct stack **stack)
    /*@
    requires
        pointer(stack, ?s0) &*& stack(s0, ?elems) &*&
        switch (elems) {
            case nil: return ensures false;
            case cons(head, tail): return
                ensures pointer(stack, ?s1) &*& stack(s1, tail) &*& result == head;
        };
    @*/
    //@ ensures true;
{
    struct stack *s = *stack;
    if (s == 0)
        error("stack_pop: stack underflow");
    else {
        void *result = s->head;
        *stack = s->tail;
        free(s);
        return result;
    }
}

typedef bool start_marking_func/*@(predicate(void *; list<object>) inv, predicate(void *, list<object>, int, object) markingInv)@*/(struct object **object, struct object **parent);
    //@ requires pointer(object, ?o) &*& pointer(parent, ?p) &*& inv(o, ?children);
    /*@
    ensures
        switch (children) {
            case nil: return !result &*& pointer(object, o) &*& pointer(parent, p) &*& inv(o, children);
            case cons(h, t): return result &*& pointer(object, h) &*& pointer(parent, o) &*& markingInv(o, children, 0, p);
        };
    @*/
typedef bool mark_next_func/*@(predicate(void *; list<object>) inv, predicate(void *, list<object>, int, object) markingInv)@*/(struct object **object, struct object **parent);
    //@ requires pointer(object, ?o) &*& pointer(parent, ?p) &*& markingInv(p, ?children, ?i, ?gp) &*& o == nth(i, children);
    /*@
    ensures
        i + 1 == length(children) ?
            !result &*& pointer(object, p) &*& pointer(parent, gp) &*& inv(p, children)
        :
            result &*& pointer(object, nth(i + 1, children)) &*& pointer(parent, p) &*& markingInv(p, children, i + 1, gp);
    @*/

typedef void dispose_func/*@(predicate(void *; list<object>) inv)@*/(struct object *object);
    //@ requires object->next |-> _ &*& object->marked |-> _ &*& object->class |-> _ &*& struct_object_padding(object) &*& inv(object, _);
    //@ ensures true;

struct class {
    char *name;
    //@ predicate(void *; list<object>) inv;
    //@ predicate(void *, list<object>, int, object) marking_inv;
    start_marking_func *start_marking;
    mark_next_func *mark_next;
    dispose_func *dispose;
};

struct object {
    struct object *next;
    bool marked;
    struct class *class;
};

struct object *heap_head = 0;

struct stack *roots_head = 0;

int object_count = 0;

typedef struct object *object;

/*@

predicate object_list(object head, list<object> elems) =
    head == 0 ?
        elems == nil
    :
        head->next |-> ?next &*&
        object_list(next, ?elems0) &*&
        elems == cons(head, elems0);

lemma void object_list_next_absurd(object o)
    requires object_list(?head, ?elems) &*& o->next |-> ?n;
    ensures object_list(head, elems) &*& o->next |-> n &*& !mem(o, elems);
{
    open object_list(head, elems);
    if (head == 0) {
    } else {
        object_list_next_absurd(o);
    }
    close object_list(head, elems);
}

lemma void object_list_nonzero()
    requires object_list(?head, ?elems);
    ensures object_list(head, elems) &*& !mem<object>(0, elems);
{
    open object_list(head, elems);
    if (head == 0) {
    } else {
        object_list_nonzero();
    }
    close object_list(head, elems);
}

predicate class(struct class *class; predicate(object; list<object>) inv, predicate(object, list<object>, int, object) markingInv) =
    [_]class->inv |-> inv &*&
    [_]class->marking_inv |-> markingInv &*&
    [_]class->start_marking |-> ?startMarking &*& [_]is_start_marking_func(startMarking, inv, markingInv) &*&
    [_]class->mark_next |-> ?markNext &*& [_]is_mark_next_func(markNext, inv, markingInv) &*&
    [_]class->dispose |-> ?dispose &*& [_]is_dispose_func(dispose, inv);

predicate_ctor object(list<object> allObjects)(object object) =
    object->marked |-> false &*&
    object->class |-> ?class &*&
    struct_object_padding(object) &*&
    [_]class->inv |-> ?inv &*& inv(object, ?children) &*&
    subset(children, allObjects) == true &*&
    [_]class->marking_inv |-> ?markingInv &*&
    [_]class->start_marking |-> ?startMarking &*& [_]is_start_marking_func(startMarking, inv, markingInv) &*&
    [_]class->mark_next |-> ?markNext &*& [_]is_mark_next_func(markNext, inv, markingInv) &*&
    [_]class->dispose |-> ?dispose &*& [_]is_dispose_func(dispose, inv);

lemma void open_object_with_closed_class(list<object> allObjects, object object)
    requires object(allObjects)(object);
    ensures
        object->marked |-> false &*&
        object->class |-> ?class &*&
        struct_object_padding(object) &*&
        class(class, ?inv, ?markingInv) &*& inv(object, ?children) &*&
        subset(children, allObjects) == true;
{
    open object(allObjects)(object);
    close class(object->class, _, _);
}

predicate_ctor root0(list<object> allObjects)(object *root) = [1/2]pointer(root, ?r) &*& mem(r, allObjects) == true;

predicate heap(list<object> objects, list<object *> roots) =
    pointer(&heap_head, ?objectsHead) &*& object_list(objectsHead, objects) &*&
    pointer(&roots_head, ?rootsHead) &*& stack(rootsHead, roots) &*&
    integer(&object_count, _) &*&
    foreach(objects, object(objects)) &*&
    foreach(roots, root0(objects));

lemma void foreach_object_mono(list<object> objects0, list<object> objects1)
    requires foreach(?xs, object(objects0)) &*& subset(objects0, objects1) == true;
    ensures foreach(xs, object(objects1));
{
    open foreach(_, _);
    switch (xs) {
        case nil:
        case cons(x, xs0):
            open object(objects0)(x);
            assert x->class |-> ?class &*& [_]class->inv |-> ?inv &*& inv(x, ?children);
            subset_trans(children, objects0, objects1);
            close object(objects1)(x);
            foreach_object_mono(objects0, objects1);
    }
    close foreach(xs, object(objects1));
}

lemma void foreach_root0_mono(list<object> objects0, list<object> objects1)
    requires foreach(?xs, root0(objects0)) &*& subset(objects0, objects1) == true;
    ensures foreach(xs, root0(objects1));
{
    open foreach(_, _);
    switch (xs) {
        case nil:
        case cons(x, xs0):
            open root0(objects0)(?root);
            assert [_]pointer(root, ?r);
            mem_subset(r, objects0, objects1);
            close root0(objects1)(root);
            foreach_root0_mono(objects0, objects1);
    }
    close foreach(xs, root0(objects1));
}

predicate_ctor marked_object(list<object> markedObjects)(object object) =
    object->marked |-> true &*&
    object->class |-> ?class &*&
    struct_object_padding(object) &*& 
    [_]class->inv |-> ?inv &*& inv(object, ?children) &*&
    subset(children, markedObjects) == true &*&
    [_]class->marking_inv |-> ?markingInv &*&
    [_]class->start_marking |-> ?startMarking &*& [_]is_start_marking_func(startMarking, inv, markingInv) &*&
    [_]class->mark_next |-> ?markNext &*& [_]is_mark_next_func(markNext, inv, markingInv) &*&
    [_]class->dispose |-> ?dispose &*& [_]is_dispose_func(dispose, inv);

lemma void foreach_marked_object_mono(list<object> markedObjects0, list<object> markedObjects1)
    requires foreach(?xs, marked_object(markedObjects0)) &*& subset(markedObjects0, markedObjects1) == true;
    ensures foreach(xs, marked_object(markedObjects1));
{
    open foreach(_, _);
    switch (xs) {
        case nil:
        case cons(x, xs0):
            open marked_object(markedObjects0)(x);
            assert x->class |-> ?class &*& [_]class->inv |-> ?inv &*& inv(x, ?children);
            subset_trans(children, markedObjects0, markedObjects1);
            close marked_object(markedObjects1)(x);
            foreach_marked_object_mono(markedObjects0, markedObjects1);
    }
    close foreach(xs, marked_object(markedObjects1));
}

predicate busy_object(object object) = object->marked |-> true;

predicate heap_marking(list<object> objects, list<object> busyObjects, list<object> markedObjects) =
    foreach(remove_all(markedObjects, objects), object(objects)) &*& !mem<struct object *>(0, objects) == true &*&
    subset(busyObjects, markedObjects) == true &*&
    subset(markedObjects, objects) == true &*&
    foreach(busyObjects, busy_object) &*&
    foreach(remove_all(busyObjects, markedObjects), marked_object(markedObjects));

@*/

void push_root(struct object **root)
    //@ requires heap(?objects, ?roots) &*& [1/2]pointer(root, ?r) &*& mem(r, objects) == true;
    //@ ensures heap(objects, cons(root, roots));
{
    //@ open heap(_, _);
    stack_push(&roots_head, root);
    //@ close root0(objects)(root);
    //@ close foreach(cons(root, roots), root0(objects));
    //@ close heap(objects, cons(root, roots));
}

/*@

lemma void root_mem(object *root)
    requires heap(?objects, ?roots) &*& [?f]pointer(root, ?r) &*& mem(root, roots) == true;
    ensures heap(objects, roots) &*& [f]pointer(root, r) &*& mem(r, objects) == true;
{
    open heap(objects, roots);
    foreach_remove(root, roots);
    open root0(objects)(root);
    assume(0 < f);
    close root0(objects)(root);
    foreach_unremove(root, roots);
    close heap(objects, roots);
}

@*/

void set_root(object *root, object value)
    //@ requires heap(?objects, ?roots) &*& [1/2]pointer(root, _) &*& mem(root, roots) == true &*& mem(value, objects) == true;
    //@ ensures heap(objects, roots) &*& [1/2]pointer(root, value);
{
    //@ open heap(objects, roots);
    //@ foreach_remove(root, roots);
    //@ open root0(objects)(root);
    *root = value;
    //@ close root0(objects)(root);
    //@ foreach_unremove(root, roots);
    //@ close heap(objects, roots);
}

void pop_root()
    //@ requires heap(?objects, ?roots);
    //@ ensures heap(objects, tail(roots)) &*& [1/2]pointer(head(roots), _);
{
    //@ open heap(_, _);
    stack_pop(&roots_head);
    //@ open foreach(roots, root0(objects));
    //@ open root0(objects)(head(roots));
    //@ close heap(objects, tail(roots));
}

/*@

predicate mark_stack(list<object> objects, list<object> markedObjects, object root, object object, object child, list<object> busyObjects) =
    object == 0 ?
        busyObjects == nil &*& child == root
    :
        mem(object, markedObjects) == true &*&
        object->class |-> ?class &*&
        struct_object_padding(object) &*& 
        [_]class->inv |-> ?inv &*&
        [_]class->marking_inv |-> ?markingInv &*& markingInv(object, ?children, ?i, ?parent) &*& 0 <= i &*& i < length(children) &*&
        subset(children, objects) == true &*&
        subset(take(i, children), markedObjects) == true &*&
        child == nth(i, children) &*&
        [_]class->start_marking |-> ?startMarking &*& [_]is_start_marking_func(startMarking, inv, markingInv) &*&
        [_]class->mark_next |-> ?markNext &*& [_]is_mark_next_func(markNext, inv, markingInv) &*&
        [_]class->dispose |-> ?dispose &*& [_]is_dispose_func(dispose, inv) &*&
        mark_stack(objects, markedObjects, root, parent, object, ?busyObjectsTail) &*&
        busyObjects == cons(object, busyObjectsTail);

lemma void mark_stack_mono(list<object> markedObjects0, list<object> markedObjects1)
    requires mark_stack(?objects, markedObjects0, ?r, ?o, ?c, ?busyObjects) &*& subset(markedObjects0, markedObjects1) == true;
    ensures mark_stack(objects, markedObjects1, r, o, c, busyObjects);
{
    open mark_stack(_, _, _, _, _, _);
    if (o == 0) {
    } else {
        assert o->class |-> ?class &*& [_]class->marking_inv |-> ?markingInv &*& markingInv(o, ?children, ?i, _);
        mem_subset(o, markedObjects0, markedObjects1);
        subset_trans(take(i, children), markedObjects0, markedObjects1);
        mark_stack_mono(markedObjects0, markedObjects1);
    }
    close mark_stack(objects, markedObjects1, r, o, c, busyObjects);
}

lemma void mark_stack_not_mem(object o)
    requires mark_stack(?objects, ?markedObjects, ?r, ?o0, ?c, ?busyObjects) &*& o->class |-> ?class;
    ensures mark_stack(objects, markedObjects, r, o0, c, busyObjects) &*& o->class |-> class &*& !mem(o, busyObjects);
{
    open mark_stack(_, _, _, _, _, _);
    if (o0 == 0) {
    } else {
        mark_stack_not_mem(o);
    }
    close mark_stack(objects, markedObjects, r, o0, c, busyObjects);
}

@*/

void mark(struct object *object)
    //@ requires heap_marking(?objects, nil, ?markedObjects0) &*& mem(object, objects) == true;
    //@ ensures heap_marking(objects, nil, ?markedObjects1) &*& subset(markedObjects0, markedObjects1) == true &*& mem(object, markedObjects1) == true;
{
    struct object *parent = 0;
    struct object *root = object;
    //@ close mark_stack(objects, markedObjects0, object, 0, object, nil);
start_marking:
    /*@
    invariant
        pointer(&object, ?o) &*& pointer(&parent, ?p) &*&
        heap_marking(objects, ?busyObjects, ?markedObjects) &*& subset(markedObjects0, markedObjects) == true &*&
        mark_stack(objects, markedObjects, root, p, o, busyObjects) &*&
        mem(o, objects) == true;
    @*/
    //@ open heap_marking(_, _, _);
    /*@
    if (mem(object, busyObjects)) {
        foreach_remove(object, busyObjects);
        open busy_object(object);
    } else if (mem(object, markedObjects)) {
        mem_remove_all(object, busyObjects, markedObjects);
        foreach_remove(object, remove_all(busyObjects, markedObjects));
        open marked_object(markedObjects)(object);
    } else {
        mem_remove_all(object, markedObjects, objects);
        foreach_remove(object, remove_all(markedObjects, objects));
        open object(objects)(object);
    }
    @*/
    if (object->marked) {
        /*@
        if (mem(object, busyObjects)) {
            close busy_object(object);
            foreach_unremove(object, busyObjects);
            mem_subset(object, busyObjects, markedObjects);
            close heap_marking(objects, busyObjects, markedObjects);
        } else if (mem(object, markedObjects)) {
            close marked_object(markedObjects)(object);
            foreach_unremove(object, remove_all(busyObjects, markedObjects));
            close heap_marking(objects, busyObjects, markedObjects);
        }
        @*/
        goto mark_next;
    } else {
        start_marking_func *startMarkingFunc = object->class->start_marking;
        object->marked = true;
        //@ subset_cons(o, busyObjects);
        //@ subset_cons(o, markedObjects);
        //@ subset_trans(busyObjects, markedObjects, cons(o, markedObjects));
        //@ subset_trans(markedObjects0, markedObjects, cons(o, markedObjects));
        //@ close busy_object(o);
        //@ close foreach(cons(o, busyObjects), busy_object);
        //@ remove_remove_all(o, busyObjects, cons(o, markedObjects));
        //@ foreach_marked_object_mono(markedObjects, cons(o, markedObjects));
        //@ close heap_marking(objects, cons(o, busyObjects), cons(o, markedObjects));
        //@ mark_stack_mono(markedObjects, cons(o, markedObjects));
        if (startMarkingFunc(&object, &parent)) {
            //@ close mark_stack(objects, cons(o, markedObjects), root, parent, object, cons(o, busyObjects));
            goto start_marking;
        } else {
            //@ open heap_marking(_, _, ?markedObjects1);
            //@ open foreach(cons(object, busyObjects), _);
            //@ mem_remove_all(object, busyObjects, markedObjects1);
            //@ open busy_object(object);
            //@ close marked_object(markedObjects1)(object);
            //@ foreach_unremove(object, remove_all(busyObjects, markedObjects1));
            //@ close heap_marking(objects, busyObjects, markedObjects1);
            goto mark_next;
        }
    }
mark_next:
    /*@
    invariant
        pointer(&object, ?o) &*& pointer(&parent, ?p) &*&
        heap_marking(objects, ?busyObjects, ?markedObjects) &*& subset(markedObjects0, markedObjects) == true &*&
        mark_stack(objects, markedObjects, root, p, o, busyObjects) &*&
        mem(o, markedObjects) == true;
    @*/
    if (parent == 0) {
        //@ open mark_stack(_, _, _, _, _, _);
        return;
    }
    {
        //@ open mark_stack(_, _, _, _, _, _);
        mark_next_func *markNextFunc = parent->class->mark_next;
        //@ assert object_class(p, ?class) &*& [_]class->marking_inv |-> ?markingInv &*& markingInv(p, ?children, ?i, _);
        if (markNextFunc(&object, &parent)) {
            //@ take_plus_one(i, children);
            //@ forall_append(take(i, children), cons(o, nil), (contains)(markedObjects));
            //@ close mark_stack(objects, markedObjects, root, p, object, busyObjects);
            //@ mem_subset(object, children, objects);
            goto start_marking;
        } else {
            //@ open heap_marking(_, _, ?markedObjects1);
            //@ open foreach(busyObjects, _);
            //@ mark_stack_not_mem(p);
            //@ mem_remove_all(p, tail(busyObjects), markedObjects1);
            //@ open busy_object(p);
            //@ assert subset(take(length(children) - 1, children), markedObjects1) == true;
            //@ assert o == nth(length(children) - 1, children) &*& mem(o, markedObjects1) == true;
            //@ drop_n_plus_one(length(children) - 1, children);
            //@ append_take_drop_n(children, length(children) - 1);
            //@ take_plus_one(length(children) - 1, children);
            //@ drop_length(children);
            //@ take_length(children);
            //@ forall_append(take(length(children) - 1, children), cons(o, nil), (contains)(markedObjects1));
            //@ assert subset(take(length(children), children), markedObjects1) == true;
            //@ close marked_object(markedObjects1)(p);
            //@ foreach_unremove(p, remove_all(tail(busyObjects), markedObjects1));
            //@ close heap_marking(objects, tail(busyObjects), markedObjects1);
            goto mark_next;
        }
    }
}

void gc()
    //@ requires heap(?objects, ?roots);
    //@ ensures heap(_, roots);
{
    //@ open heap(_, _);
    struct stack *rs = roots_head;
    //@ close foreach(nil, busy_object);
    //@ close foreach(nil, marked_object(nil));
    //@ object_list_nonzero();
    //@ close heap_marking(objects, nil, nil);
    for (;;)
        /*@
        requires
            stack(rs, ?roots1) &*& foreach(roots1, root0(objects)) &*&
            heap_marking(objects, nil, ?markedObjects0);
        @*/
        /*@
        ensures
            heap_marking(objects, nil, ?markedObjects1) &*& subset(markedObjects0, markedObjects1) == true &*&
            stack(old_rs, roots1) &*& foreach(roots1, root0(markedObjects1));
        @*/
    {
        if (rs == 0) {
            //@ open stack(rs, roots1);
            //@ open foreach(roots1, root0(objects));
            //@ close stack(rs, roots1);
            //@ close foreach(roots1, root0(markedObjects0));
            break;
        }
        //@ open stack(rs, _);
        //@ open foreach(roots1, _);
        //@ open root0(objects)(?root);
        //@ assert [_]pointer(root, ?r);
        mark(*((struct object **)rs->head));
        //@ assert heap_marking(objects, nil, ?markedObjects2);
        rs = rs->tail;
        //@ recursive_call();
        //@ assert heap_marking(objects, nil, ?markedObjects1);
        //@ subset_trans(markedObjects0, markedObjects2, markedObjects1);
        //@ mem_subset(r, markedObjects2, markedObjects1);
        //@ close root0(markedObjects1)(root);
        //@ close foreach(roots1, root0(markedObjects1));
    }

    {
        //@ open heap_marking(objects, nil, ?markedObjects);
        //@ open foreach(nil, busy_object);
        //@ subset_intersection(markedObjects, objects);
        //@ subset_remove_all(markedObjects, objects);
        //@ subset_intersection(remove_all(markedObjects, objects), objects);
        //@ assert intersection(objects, markedObjects) == markedObjects;
        struct object **h = &heap_head;
        for (;;)
            /*@
            requires
                pointer(h, ?head) &*& object_list(head, ?objects1) &*& subset(objects1, objects) == true &*&
                integer(&object_count, _) &*&
                foreach(intersection(objects1, remove_all(markedObjects, objects)), object(objects)) &*&
                foreach(intersection(objects1, markedObjects), marked_object(markedObjects));
            @*/
            /*@
            ensures
                pointer(old_h, ?head1) &*& object_list(head1, intersection(markedObjects, objects1)) &*&
                integer(&object_count, _) &*&
                foreach(intersection(markedObjects, objects1), object(markedObjects));
            @*/
        {
            struct object *o = *h;
            //@ open object_list(_, _);
            if (o == 0) {
                //@ open foreach(nil, _);
                //@ open foreach(nil, _);
                //@ close object_list(head, nil);
                //@ close foreach(nil, object(markedObjects));
                break;
            }
            //@ object_list_next_absurd(o);
            /*@
            if (mem(o, markedObjects)) {
                mem_intersection(o, objects1, markedObjects);
                foreach_remove(o, intersection(objects1, markedObjects));
                open marked_object(markedObjects)(o);
            } else {
                mem_remove_all(o, markedObjects, objects);
                mem_intersection(o, objects1, remove_all(markedObjects, objects));
                foreach_remove(o, intersection(objects1, remove_all(markedObjects, objects)));
                open object(objects)(o);
            }
            @*/
            if (o->marked) {
                o->marked = false;
                h = &o->next;
                /*@
                if (mem(o, remove_all(markedObjects, objects))) {
                    mem_intersection(o, objects1, remove_all(markedObjects, objects));
                    foreach_remove(o, intersection(objects1, remove_all(markedObjects, objects)));
                    open object(objects)(o);
                    assert false;
                }
                @*/
                //@ not_mem_intersection(o, objects1, remove_all(markedObjects, objects));
                /*@
                if (mem(o, remove(o, intersection(objects1, markedObjects)))) {
                    foreach_remove(o, remove(o, intersection(objects1, markedObjects)));
                    open marked_object(markedObjects)(o);
                    assert false;
                }
                @*/
                //@ remove_intersection(o, objects1, markedObjects);
            } else {
                /*@
                if (mem(o, remove(o, intersection(objects1, remove_all(markedObjects, objects))))) {
                    foreach_remove(o, remove(o, intersection(objects1, remove_all(markedObjects, objects))));
                    open object(objects)(o);
                    assert false;
                }
                @*/
                dispose_func *disposeFunc = o->class->dispose;
                object_count--;
                *h = o->next;
                disposeFunc(o);
                //@ remove_intersection(o, objects1, remove_all(markedObjects, objects));
                //@ not_mem_intersection(o, objects1, markedObjects);
                
            }
            //@ recursive_call();
            /*@
            if (mem(o, markedObjects)) {
                close object_list(o, intersection(markedObjects, objects1));
                close object(markedObjects)(o);
                close foreach(intersection(markedObjects, objects1), object(markedObjects));
            }
            @*/
        }
        //@ subset_intersection_subset(markedObjects, objects);
        //@ foreach_object_mono(markedObjects, intersection(markedObjects, objects));
        //@ foreach_root0_mono(markedObjects, intersection(markedObjects, objects));
        //@ close heap(intersection(markedObjects, objects), roots);
    }
}

/*@

predicate roots(list<object *> allRoots, list<object *> rs; list<object> vs) =
    switch (rs) {
        case nil: return vs == nil;
        case cons(r, rs0): return
            [1/2]pointer(r, ?v) &*& mem(r, allRoots) == true &*& roots(allRoots, rs0, ?vs0) &*& vs == cons(v, vs0);
    };

lemma void roots_lemma(list<object> objects)
    requires roots(?roots, ?rs, ?vs) &*& foreach(roots, root0(objects));
    ensures roots(roots, rs, vs) &*& foreach(roots, root0(objects)) &*& subset(vs, objects) == true;
{
    open roots(roots, rs, vs);
    switch (rs) {
        case nil:
        case cons(r, rs0):
            foreach_remove(r, roots);
            open root0(objects)(r);
            close root0(objects)(r);
            foreach_unremove(r, roots);
            roots_lemma(objects);
    }
    close roots(roots, rs, vs);
}

@*/

void register_object(struct object *o, struct class *class)
    /*@
    requires
        heap(?objects, ?roots) &*&
        o != 0 &*&
        o->next |-> _ &*& o->marked |-> _ &*& o->class |-> _ &*& struct_object_padding(o) &*&
        [_]class->inv |-> ?inv &*& inv(o, ?children) &*&
        roots(roots, ?childRoots, children) &*&
        [_]class->marking_inv |-> ?markingInv &*&
        [_]class->start_marking |-> ?startMarking &*& [_]is_start_marking_func(startMarking, inv, markingInv) &*&
        [_]class->mark_next |-> ?markNext &*& [_]is_mark_next_func(markNext, inv, markingInv) &*&
        [_]class->dispose |-> ?dispose &*& [_]is_dispose_func(dispose, inv);
    @*/
    //@ ensures heap(?objects1, roots) &*& mem(o, objects1) == true &*& roots(roots, childRoots, children);
{
    //@ open heap(_, _);
    if (object_count == 10000) {
        //@ close heap(objects, roots);
        gc();
        //@ open heap(?objects1, _);
        //@ objects = objects1;
    }
    if (object_count == 10000)
        error("register_object: object count limit reached.");
    object_count++;
    o->next = heap_head;
    o->marked = false;
    o->class = class;
    heap_head = o;
    //@ close object_list(o, _);
    //@ subset_cons(o, objects);
    //@ foreach_object_mono(objects, cons(o, objects));
    //@ foreach_root0_mono(objects, cons(o, objects));
    //@ roots_lemma(cons(o, objects));
    //@ close object(cons(o, objects))(o);
    //@ close foreach(cons(o, objects), object(cons(o, objects)));
    //@ close heap(cons(o, objects), roots);
}

/*@

predicate class_info() =
    [_]class_inv(&cons_class, cons_inv) &*& [_]class_marking_inv(&cons_class, cons_marking_inv) &*&
    [_]class_start_marking(&cons_class, cons_start_marking) &*& [_]is_start_marking_func(cons_start_marking, cons_inv, cons_marking_inv) &*&
    [_]class_mark_next(&cons_class, cons_mark_next) &*& [_]is_mark_next_func(cons_mark_next, cons_inv, cons_marking_inv) &*&
    [_]class_dispose(&cons_class, cons_dispose) &*& [_]is_dispose_func(cons_dispose, cons_inv) &*&
    [_]class_inv(&atom_class, atom_inv) &*& [_]class_marking_inv(&atom_class, atom_marking_inv) &*&
    [_]class_start_marking(&atom_class, atom_start_marking) &*& [_]is_start_marking_func(atom_start_marking, atom_inv, atom_marking_inv) &*&
    [_]class_mark_next(&atom_class, atom_mark_next) &*& [_]is_mark_next_func(atom_mark_next, atom_inv, atom_marking_inv) &*&
    [_]class_dispose(&atom_class, atom_dispose) &*& [_]is_dispose_func(atom_dispose, atom_inv) &*&
    [_]class_inv(&function_class, function_inv) &*& [_]class_marking_inv(&function_class, function_marking_inv) &*&
    [_]class_start_marking(&function_class, function_start_marking) &*& [_]is_start_marking_func(function_start_marking, function_inv, function_marking_inv) &*&
    [_]class_mark_next(&function_class, function_mark_next) &*& [_]is_mark_next_func(function_mark_next, function_inv, function_marking_inv) &*&
    [_]class_dispose(&function_class, function_dispose) &*& [_]is_dispose_func(function_dispose, function_inv) &*&
    emp;

fixpoint bool has_global_roots(list<object *> roots) {
    return mem(&nil_root, roots) && mem(&operand_stack, roots) && mem(&cont_stack, roots);
}

predicate globals(list<object> objects, list<object *> roots) =
    heap(objects, roots) &*&
    [_]pointer(&nil_root, &nil_value) &*& mem(&nil_root, roots) == true &*&
    [1/2]pointer(&operand_stack, _) &*& mem(&operand_stack, roots) == true &*&
    [1/2]pointer(&cont_stack, _) &*& mem(&cont_stack, roots) == true &*&
    [_]class_info();

@*/

void push_root_g(struct object **root)
    //@ requires globals(?objects, ?roots) &*& [1/2]pointer(root, ?r) &*& mem(r, objects) == true;
    //@ ensures globals(objects, cons(root, roots)) &*& has_global_roots(roots) == true;
{
    //@ open globals(_, _);
    push_root(root);
    //@ close globals(objects, cons(root, roots));
}

/*@

lemma void root_mem_g(struct object **root)
    requires globals(?objects, ?roots) &*& mem(root, roots) == true &*& [?f]pointer(root, ?r);
    ensures globals(objects, roots) &*& mem(r, objects) == true &*& [f]pointer(root, r);
{
    open globals(objects, roots);
    root_mem(root);
    close globals(objects, roots);
}

@*/

void set_root_g(object *root, object value)
    //@ requires globals(?objects, ?roots) &*& [1/2]pointer(root, _) &*& mem(root, roots) == true &*& mem(value, objects) == true;
    //@ ensures globals(objects, roots) &*& [1/2]pointer(root, value);
{
    //@ open globals(_, _);
    set_root(root, value);
    //@ close globals(objects, roots);
}

void pop_root_g()
    //@ requires globals(?objects, ?roots) &*& has_global_roots(tail(roots)) == true;
    //@ ensures globals(objects, tail(roots)) &*& [1/2]pointer(head(roots), _);
{
    //@ open globals(_, _);
    pop_root();
    //@ close globals(objects, tail(roots));
}

bool nil_start_marking(struct object **object, struct object **parent)
    //@ requires pointer(object, ?o) &*& pointer(parent, ?p) &*& nil_inv(o, ?children);
    /*@
    ensures
        switch (children) {
            case nil: return !result &*& pointer(object, o) &*& pointer(parent, p) &*& nil_inv(o, children);
            case cons(h, t): return result &*& pointer(object, h) &*& pointer(parent, o) &*& nil_marking_inv(o, children, 0, p);
        };
    @*/
{
    //@ open nil_inv(_, _);
    return false;
    //@ close nil_inv(o, nil);
}

bool nil_mark_next(struct object **object, struct object **parent)
    //@ requires pointer(object, ?o) &*& pointer(parent, ?p) &*& nil_marking_inv(p, ?children, ?i, ?gp) &*& o == nth(i, children);
    /*@
    ensures
        i + 1 == length(children) ?
            !result &*& pointer(object, p) &*& pointer(parent, gp) &*& nil_inv(p, children)
        :
            result &*& pointer(object, nth(i + 1, children)) &*& pointer(parent, p) &*& nil_marking_inv(p, children, i + 1, gp);
    @*/
{
    //@ open nil_marking_inv(_, _, _, _);
    assert(false);
}

void nil_dispose(void *o)
    //@ requires true;
    //@ ensures false;
{
    abort();
}

struct class nil_class = {"nil_value", nil_start_marking, nil_mark_next, nil_dispose};

//@ predicate nil_inv(object o; list<object> children) = children == nil;
//@ predicate nil_marking_inv(object o, list<object> children, int i, object parent) = false;

struct object nil_value = {0, false, &nil_class};

struct object *nil_root = &nil_value;

struct object *create_nil()
    //@ requires globals(?objects, ?roots);
    //@ ensures globals(objects, roots) &*& mem(result, objects) == true;
{
    //@ open globals(_, _);
    //@ root_mem(&nil_root);
    return &nil_value;
    //@ close globals(objects, roots);
}

struct cons {
    struct object object;
    bool tail_is_next;
    struct object *head;
    struct object *tail;
};

/*@

predicate cons_inv(struct cons *cons; list<object> children) =
    cons->tail_is_next |-> _ &*&
    cons->head |-> ?head &*&
    cons->tail |-> ?tail &*&
    malloc_block_cons(cons) &*&
    children == cons(head, cons(tail, nil));

predicate cons_children(object head, object tail) = true;

predicate cons_marking_inv(struct cons *cons, list<object> children, int i, object parent) =
    cons->tail_is_next |-> i == 0 &*&
    malloc_block_cons(cons) &*&
    cons_children(?h, ?t) &*& children == cons(h, cons(t, nil)) &*&
    i == 0 ?
        cons->head |-> parent &*&
        cons->tail |-> t
    :
        i == 1 &*&
        cons->head |-> h &*&
        cons->tail |-> parent;

@*/

bool cons_start_marking(struct object **object, struct object **parent)
    //@ requires pointer(object, ?o) &*& pointer(parent, ?p) &*& cons_inv(o, ?children);
    /*@
    ensures
        switch (children) {
            case nil: return !result &*& pointer(object, o) &*& pointer(parent, p) &*& cons_inv(o, children);
            case cons(h, t): return result &*& pointer(object, h) &*& pointer(parent, o) &*& cons_marking_inv(o, children, 0, p);
        };
    @*/
{
    struct cons *cons = (void *)*object;
    //@ open cons_inv(cons, _);
    //@ close cons_children(cons->head, cons->tail);
    *object = cons->head;
    cons->head = *parent;
    *parent = (void *)cons;
    cons->tail_is_next = true;
    return true;
    //@ close cons_marking_inv(o, children, 0, p);
}

bool cons_mark_next(struct object **object, struct object **parent)
    //@ requires pointer(object, ?o) &*& pointer(parent, ?p) &*& cons_marking_inv(p, ?children, ?i, ?gp) &*& o == nth(i, children);
    /*@
    ensures
        i + 1 == length(children) ?
            !result &*& pointer(object, p) &*& pointer(parent, gp) &*& cons_inv(p, children)
        :
            result &*& pointer(object, nth(i + 1, children)) &*& pointer(parent, p) &*& cons_marking_inv(p, children, i + 1, gp);
    @*/
{
    struct cons *cons = (void *)*parent;
    //@ open cons_marking_inv(cons, _, _, _);
    if (cons->tail_is_next) {
        struct object *grandparent = cons->head;
        cons->head = *object;
        *object = cons->tail;
        cons->tail = grandparent;
        cons->tail_is_next = false;
        //@ close cons_marking_inv(p, children, i + 1, gp);
        return true;
    } else {
        *parent = cons->tail;
        cons->tail = *object;
        *object = (void *)cons;
        return false;
        //@ open cons_children(_, _);
    }
}

void cons_dispose(struct object *object)
    //@ requires object->next |-> _ &*& object->marked |-> _ &*& object->class |-> _ &*& struct_object_padding(object) &*& cons_inv((void *)object, _);
    //@ ensures true;
{
    struct cons *cons = (void *)object;
    free(cons);
}

struct class cons_class = {"cons", cons_start_marking, cons_mark_next, cons_dispose};

struct cons *create_cons(struct object *head, struct object *tail)
    //@ requires globals(?objects, ?roots) &*& mem(head, objects) == true &*& mem(tail, objects) == true;
    //@ ensures globals(?objects1, roots) &*& mem<void *>(result, objects1) == true;
{
    //@ open globals(_, _);
    //@ open class_info();
    struct cons *cons = malloc(sizeof(struct cons));
    if (cons == 0) error("create_cons: out of memory");
    cons->head = head;
    cons->tail = tail;
    push_root(&head);
    push_root(&tail);
    //@ close roots(cons(&tail, cons(&head, roots)), nil, _);
    //@ close roots(cons(&tail, cons(&head, roots)), cons(&tail, nil), _);
    //@ close roots(cons(&tail, cons(&head, roots)), cons(&head, cons(&tail, nil)), _);
    register_object((void *)cons, &cons_class);
    //@ open roots(_, _, _);
    //@ open roots(_, _, _);
    //@ open roots(_, _, _);
    pop_root();
    pop_root();
    return cons;
    //@ close globals(_, _);
}

void destruct_cons(struct object *object, struct object **head, struct object **tail)
    //@ requires globals(?objects, ?roots) &*& mem(object, objects) == true &*& *head |-> _ &*& *tail |-> _;
    //@ ensures globals(objects, roots) &*& pointer(head, ?h) &*& mem(h, objects) == true &*& pointer(tail, ?t) &*& mem(t, objects) == true;
{
    //@ open globals(_, _);
    //@ open heap(_, _);
    //@ foreach_remove(object, objects);
    //@ open object(objects)(object);
    if (object->class != &cons_class)
        error("cons expected");
    else {
        struct cons *cons = (void *)object;
        //@ open class_info();
        //@ pointer_fractions_same_address(&object->class->dispose, &cons_class.dispose);
        //@ merge_fractions cons_class.inv |-> _;
        //@ open cons_inv(cons, ?cs);
        *head = cons->head;
        *tail = cons->tail;
        //@ close cons_inv(cons, cs);
        //@ close object(objects)(object);
        //@ foreach_unremove(object, objects);
        //@ close heap(objects, roots);
        //@ close globals(objects, roots);
    }
}

struct atom {
    struct object object;
    struct string_buffer *chars;
};

/*@

predicate atom_inv(struct atom *atom; list<object> children) =
    atom->chars |-> ?buffer &*& string_buffer(buffer, _) &*& malloc_block_atom(atom) &*& children == nil;

predicate atom_marking_inv(struct atom *atom, list<object> children, int i, object parent) = false;

@*/

bool atom_start_marking(struct object **object, struct object **parent)
    //@ requires pointer(object, ?o) &*& pointer(parent, ?p) &*& atom_inv(o, ?children);
    /*@
    ensures
        switch (children) {
            case nil: return !result &*& pointer(object, o) &*& pointer(parent, p) &*& atom_inv(o, children);
            case cons(h, t): return result &*& pointer(object, h) &*& pointer(parent, o) &*& atom_marking_inv(o, children, 0, p);
        };
    @*/
{
    return false;
    //@ open atom_inv(?atom, ?cs);
    //@ close atom_inv(atom, cs);
}

bool atom_mark_next(struct object **object, struct object **parent)
    //@ requires pointer(object, ?o) &*& pointer(parent, ?p) &*& atom_marking_inv(p, ?children, ?i, ?gp) &*& o == nth(i, children);
    /*@
    ensures
        i + 1 == length(children) ?
            !result &*& pointer(object, p) &*& pointer(parent, gp) &*& atom_inv(p, children)
        :
            result &*& pointer(object, nth(i + 1, children)) &*& pointer(parent, p) &*& atom_marking_inv(p, children, i + 1, gp);
    @*/
{
    //@ open atom_marking_inv(_, _, _, _);
    assert(false);
}

void atom_dispose(struct object *object)
    //@ requires object->next |-> _ &*& object->marked |-> _ &*& object->class |-> _ &*& struct_object_padding(object) &*& atom_inv((void *)object, _);
    //@ ensures true;
{
    struct atom *atom = (void *)object;
    string_buffer_dispose(atom->chars);
    free(atom);
}

struct class atom_class = {"atom", atom_start_marking, atom_mark_next, atom_dispose};

struct atom *create_atom(struct string_buffer *buffer)
    //@ requires globals(?objects0, ?roots) &*& string_buffer(buffer, _);
    //@ ensures globals(?objects1, roots) &*& mem((void *)result, objects1) == true;
{
    //@ open globals(_, _);
    //@ open class_info();
    struct atom *atom = malloc(sizeof(struct atom));
    if (atom == 0) abort();
    atom->chars = buffer;
    //@ close roots(roots, nil, nil);
    register_object((void *)atom, &atom_class);
    return atom;
    //@ close globals(_, _);
}

struct atom *create_atom_from_string(char *string)
    //@ requires globals(?objects0, ?roots) &*& [?f]string(string, ?cs);
    //@ ensures globals(?objects1, roots) &*& [f]string(string, cs) &*& mem((void *)result, objects1) == true;
{
    struct string_buffer *buffer = create_string_buffer();
    string_buffer_append_string(buffer, string);
    return create_atom(buffer);
}

struct object *parse(struct tokenizer *tokenizer)
    //@ requires globals(?objects0, ?roots) &*& Tokenizer(tokenizer);
    //@ ensures globals(?objects, roots) &*& Tokenizer(tokenizer) &*& mem(result, objects) == true;
{
    struct object *parent = create_nil();
    //@ open globals(_, _);
    push_root(&parent);
    //@ close globals(objects0, cons(&parent, roots));
    for (;;)
        //@ invariant globals(?objects, cons(&parent, roots)) &*& Tokenizer(tokenizer) &*& [1/2]pointer(&parent, ?p) &*& mem(p, objects) == true;
    {
        int token = tokenizer_next(tokenizer);
        if (token == 'S') {
            struct atom *atom;
            struct object *expr;
            struct string_buffer *buffer = tokenizer_get_buffer(tokenizer);
            buffer = string_buffer_copy(buffer);
            //@ tokenizer_merge_buffer(tokenizer);
            atom = create_atom(buffer);
            expr = (void *)atom;
            //@ open globals(?objects1, _);
            //@ root_mem(&parent);
            push_root(&expr);
            //@ close globals(objects1, cons(&expr, cons(&parent, roots)));
            for (;;)
                /*@
                invariant
                    globals(?objects2, cons(&expr, cons(&parent, roots))) &*& Tokenizer(tokenizer) &*&
                    [1/2]pointer(&parent, ?p2) &*& mem(p2, objects2) == true &*&
                    [1/2]pointer(&expr, ?e2) &*& mem(e2, objects2) == true;
                @*/
            {
                if (parent == &nil_value) {
                    //@ open globals(_, _);
                    pop_root();
                    pop_root();
                    //@ close globals(objects2, roots); 
                    return expr;
                } else {
                    struct cons *parentCons = (void *)parent;
                    //@ open globals(_, _);
                    //@ open heap(_, _);
                    //@ foreach_remove(parent, objects2);
                    //@ open object(objects2)(parent);
                    if (parent->class != &cons_class) abort();
                    //@ open class_info();
                    //@ pointer_fractions_same_address(&parent->class->dispose, &cons_class.dispose);
                    //@ merge_fractions cons_class.inv |-> _;
                    //@ open cons_inv(parentCons, _);
                    if (parentCons->head == &nil_value) {
                        parentCons->head = expr;
                        //@ close cons_inv(parentCons, _);
                        //@ close object(objects2)(parent);
                        //@ foreach_unremove(parent, objects2);
                        //@ close heap(objects2, cons(&expr, cons(&parent, roots)));
                        break;
                    } else {
                        struct object *newParent = parentCons->tail;
                        parentCons->tail = expr;
                        //@ close cons_inv(parentCons, _);
                        //@ close object(objects2)(parent);
                        //@ foreach_unremove(parent, objects2);
                        //@ close heap(objects2, cons(&expr, cons(&parent, roots)));
                        set_root(&expr, parent);
                        set_root(&parent, newParent);
                        //@ close globals(objects2, cons(&expr, cons(&parent, roots)));
                        {
                            int newToken = tokenizer_next(tokenizer);
                            if (newToken != ')') error("Syntax error: pair: missing ')'");
                        }
                    }
                }
            }
            pop_root();
            //@ assert heap(?objects3, ?roots3);
            //@ close globals(objects3, roots3);
        } else if (token == '(') {
            struct object *nilValue = create_nil();
            struct cons *cons = create_cons(nilValue, (void *)parent);
            //@ open globals(?objects2, ?roots2);
            set_root(&parent, (void *)cons);
            //@ close globals(objects2, roots2);
        } else
            error("Syntax error: expected symbol or '('");
    }
}

struct object *operand_stack = &nil_value;
struct object *cont_stack = &nil_value;

void push(struct object *object)
    //@ requires globals(?objects0, ?roots) &*& mem(object, objects0) == true;
    //@ ensures globals(?objects1, roots);
{
    //@ open globals(_, _);
    struct object *old_operand_stack = operand_stack;
    //@ root_mem(&operand_stack);
    //@ close globals(objects0, roots);
    struct cons *cons = create_cons(object, old_operand_stack);
    //@ open globals(?objects1, roots);
    set_root(&operand_stack, (void *)cons);
    //@ close globals(objects1, roots);
}

struct object *pop()
    //@ requires globals(?objects, ?roots);
    //@ ensures globals(objects, roots) &*& mem(result, objects) == true;
{
    //@ open globals(_, _);
    //@ root_mem(&operand_stack);
    struct object *old_operand_stack = operand_stack;
    //@ open heap(_, _);
    //@ foreach_remove(old_operand_stack, objects);
    //@ open object(objects)(old_operand_stack);
    if (old_operand_stack->class != &cons_class)
        error("pop: stack underflow");
    else {
        //@ open class_info();
        //@ pointer_fractions_same_address(&old_operand_stack->class->dispose, &cons_class.dispose);
        //@ merge_fractions cons_class.inv |-> _;
        struct cons *cons = (void *)operand_stack;
        //@ open cons_inv(cons, ?cs);
        struct object *result = cons->head;
        struct object *new_operand_stack = cons->tail;
        //@ close cons_inv(cons, cs);
        //@ close object(objects)(old_operand_stack);
        //@ foreach_unremove(old_operand_stack, objects);
        //@ close heap(objects, roots);
        set_root(&operand_stack, new_operand_stack);
        return result;
        //@ close globals(objects, roots);
    }
}

void push_cont(struct object *object)
    //@ requires globals(?objects0, ?roots) &*& mem(object, objects0) == true;
    //@ ensures globals(?objects1, roots);
{
    //@ open globals(_, _);
    struct object *old_cont_stack = cont_stack;
    //@ root_mem(&cont_stack);
    //@ close globals(objects0, roots);
    struct cons *cons = create_cons(object, old_cont_stack);
    //@ open globals(?objects1, roots);
    set_root(&cont_stack, (void *)cons);
    //@ close globals(objects1, roots);
}

struct object *pop_cont()
    //@ requires globals(?objects, ?roots);
    //@ ensures globals(objects, roots) &*& result == 0 ? true : mem(result, objects) == true;
{
    //@ open globals(_, _);
    //@ root_mem(&cont_stack);
    struct object *old_cont_stack = cont_stack;
    //@ open heap(_, _);
    //@ foreach_remove(old_cont_stack, objects);
    //@ open object(objects)(old_cont_stack);
    if (old_cont_stack->class != &cons_class) {
        //@ close object(objects)(old_cont_stack);
        //@ foreach_unremove(old_cont_stack, objects);
        //@ close heap(objects, roots);
        //@ close globals(objects, roots);
        return 0;
    } else {
        //@ open class_info();
        //@ pointer_fractions_same_address(&old_cont_stack->class->dispose, &cons_class.dispose);
        //@ merge_fractions cons_class.inv |-> _;
        struct cons *cons = (void *)cont_stack;
        //@ open cons_inv(cons, ?cs);
        struct object *result = cons->head;
        struct object *new_cont_stack = cons->tail;
        //@ close cons_inv(cons, cs);
        //@ close object(objects)(old_cont_stack);
        //@ foreach_unremove(old_cont_stack, objects);
        //@ close heap(objects, roots);
        set_root(&cont_stack, new_cont_stack);
        return result;
        //@ close globals(objects, roots);
    }
}

typedef void apply_func(struct object *data);
    //@ requires globals(?objects, ?roots) &*& mem(data, objects) == true;
    //@ ensures globals(_, roots);

struct function {
    struct object object;
    apply_func *apply;
    struct object *data;
};

/*@

predicate function_inv(struct function *function; list<object> children) =
    function->apply |-> ?apply &*& is_apply_func(apply) == true &*&
    function->data |-> ?data &*& children == cons(data, nil) &*&
    malloc_block_function(function);

predicate function_data_ghost(object data) = true;

predicate function_marking_inv(struct function *function, list<object> children, int i, object parent) =
    i == 0 &*&
    function_data_ghost(?data) &*&
    function->apply |-> ?apply &*& is_apply_func(apply) == true &*&
    function->data |-> parent &*& children == cons(data, nil) &*&
    malloc_block_function(function);

@*/

bool function_start_marking(struct object **object, struct object **parent)
    //@ requires pointer(object, ?o) &*& pointer(parent, ?p) &*& function_inv(o, ?children);
    /*@
    ensures
        switch (children) {
            case nil: return !result &*& pointer(object, o) &*& pointer(parent, p) &*& function_inv(o, children);
            case cons(h, t): return result &*& pointer(object, h) &*& pointer(parent, o) &*& function_marking_inv(o, children, 0, p);
        };
    @*/
{
    struct function *function = (void *)*object;
    //@ open function_inv(_, _);
    //@ close function_data_ghost(function->data);
    *object = function->data;
    function->data = *parent;
    *parent = (void *)function;
    return true;
    //@ close function_marking_inv(o, children, 0, p);
}

bool function_mark_next(struct object **object, struct object **parent)
    //@ requires pointer(object, ?o) &*& pointer(parent, ?p) &*& function_marking_inv(p, ?children, ?i, ?gp) &*& o == nth(i, children);
    /*@
    ensures
        i + 1 == length(children) ?
            !result &*& pointer(object, p) &*& pointer(parent, gp) &*& function_inv(p, children)
        :
            result &*& pointer(object, nth(i + 1, children)) &*& pointer(parent, p) &*& function_marking_inv(p, children, i + 1, gp);
    @*/
{
    struct function *function = (void *)*parent;
    //@ open function_marking_inv(_, _, _, _);
    *parent = function->data;
    function->data = *object;
    *object = (void *)function;
    return false;
    //@ open function_data_ghost(_);
}

void function_dispose(struct object *object)
    //@ requires object->next |-> _ &*& object->marked |-> _ &*& object->class |-> _ &*& struct_object_padding(object) &*& function_inv((void *)object, _);
    //@ ensures true;
{
    struct function *function = (void *)object;
    //@ open function_inv(function, _);
    free(function);
}

struct class function_class = {"function", function_start_marking, function_mark_next, function_dispose};

struct function *create_function(apply_func *apply, struct object *data)
    //@ requires globals(?objects, ?roots) &*& is_apply_func(apply) == true &*& mem(data, objects) == true;
    //@ ensures globals(?objects1, roots) &*& mem((void *)result, objects1) == true;
{
    struct function *function = malloc(sizeof(struct function));
    if (function == 0) abort();
    function->apply = apply;
    function->data = data;
    //@ open globals(_, _);
    //@ open class_info();
    push_root(&data);
    //@ close roots(cons(&data, roots), nil, _);
    //@ close roots(cons(&data, roots), cons(&data, nil), _);
    register_object((void *)function, &function_class);
    //@ open roots(_, _, _);
    //@ open roots(_, _, _);
    pop_root();
    return function;
    //@ assert heap(?objects1, roots);
    //@ close globals(objects1, roots);
}

void apply(struct object *function)
    //@ requires globals(?objects, ?roots) &*& mem(function, objects) == true;
    //@ ensures globals(_, roots);
{
    //@ open globals(_, _);
    //@ open heap(_, _);
    //@ foreach_remove(function, objects);
    //@ open object(objects)(function);
    if (function->class != &function_class)
        error("apply: not a function");
    {
        //@ open class_info();
        //@ pointer_fractions_same_address(&function->class->dispose, &function_class.dispose);
        //@ merge_fractions function_class.inv |-> _;
        struct function *f = (void *)function;
        //@ open function_inv(_, ?cs);
        apply_func *applyFunc = f->apply;
        struct object *data = f->data;
        //@ close function_inv(f, cs);
        //@ close object(objects)(function);
        //@ foreach_unremove(function, objects);
        //@ close heap(objects, roots);
        //@ close globals(objects, roots);
        applyFunc(data);
    }
}

void pop_apply(struct object *data) //@ : apply_func
    //@ requires globals(_, ?roots);
    //@ ensures globals(_, roots);
{
    struct object *f = pop();
    apply(f);
}

bool atom_equals(struct object *object1, struct object *object2)
    //@ requires globals(?objects, ?roots) &*& mem(object1, objects) == true &*& mem(object2, objects) == true;
    //@ ensures globals(objects, roots);
{
    if (object1 == object2)
        return true;
    //@ open globals(_, _);
    //@ open heap(_, _);
    //@ foreach_remove(object1, objects);
    //@ neq_mem_remove(object2, object1, objects);
    //@ foreach_remove(object2, remove(object1, objects));
    //@ open_object_with_closed_class(objects, object1);
    //@ open_object_with_closed_class(objects, object2);
    if (object1->class != &atom_class || object2->class != &atom_class)
        error("atom_equals: atoms expected");
    else {
        struct atom *a1 = (void *)object1;
        struct atom *a2 = (void *)object2;
        //@ open class(_, _, _);
        //@ open class(_, _, _);
        //@ open class_info();
        //@ pointer_fractions_same_address(&object1->class->dispose, &atom_class.dispose);
        //@ pointer_fractions_same_address(&object2->class->dispose, &atom_class.dispose);
        //@ merge_fractions atom_class.inv |-> _;
        //@ open atom_inv(a1, _);
        //@ open atom_inv(a2, _);
        return string_buffer_equals(a1->chars, a2->chars);
        //@ close atom_inv(a1, nil);
        //@ close atom_inv(a2, nil);
        //@ close object(objects)(object2);
        //@ close object(objects)(object1);
        //@ foreach_unremove(object2, remove(object1, objects));
        //@ foreach_unremove(object1, objects);
        //@ close heap(objects, roots);
        //@ close globals(objects, roots);
    }
}

struct object *assoc(struct object *key, struct object *map)
    //@ requires globals(?objects, ?roots) &*& mem(key, objects) == true &*& mem(map, objects) == true;
    //@ ensures globals(objects, roots) &*& result == 0 ? true : mem(result, objects) == true;
{
    for (;;)
        //@ invariant globals(objects, roots) &*& mem(map, objects) == true;
    {
        if (map == &nil_value)
            return 0;
        else {
            struct object *mapHead;
            struct object *mapTail;
            struct object *entryHead;
            struct object *entryTail;
            destruct_cons(map, &mapHead, &mapTail);
            destruct_cons(mapHead, &entryHead, &entryTail);
            if (atom_equals(key, entryHead))
                return entryTail;
            else
                map = mapTail;
        }
    }
}

void map_cons(struct atom *key, struct object *value, struct object **map)
    //@ requires globals(?objects, ?roots) &*& mem((void *)key, objects) == true &*& mem(value, objects) == true &*& [1/2]pointer(map, _) &*& mem(map, roots) == true;
    //@ ensures globals(_, roots) &*& [1/2]pointer(map, _);
{
    struct cons *entry = create_cons((void *)key, value);
    //@ root_mem_g(map);
    struct cons *cons = create_cons((void *)entry, *map);
    set_root_g(map, (void *)cons);
}

void map_cons_s(char *key, struct object *value, struct object **map)
    //@ requires globals(?objects, ?roots) &*& [?f]string(key, ?cs) &*& mem(value, objects) == true &*& [1/2]pointer(map, _) &*& mem(map, roots) == true;
    //@ ensures globals(_, roots) &*& [f]string(key, cs) &*& [1/2]pointer(map, _);
{
    struct atom *atom;
    void *result;
    
    push_root_g(&value);
    atom = create_atom_from_string(key);
    //@ root_mem_g(&value);
    pop_root_g();
    map_cons(atom, value, map);
}

void map_cons_s_func_nil(char *key, apply_func *function, struct object **map)
    //@ requires globals(?objects, ?roots) &*& [?f]string(key, ?cs) &*& is_apply_func(function) == true &*& [1/2]pointer(map, _) &*& mem(map, roots) == true;
    //@ ensures globals(_, roots) &*& [f]string(key, cs) &*& [1/2]pointer(map, _);
{
    struct object *nil = create_nil();
    void *func = create_function(function, nil);
    map_cons_s(key, func, map);
}

struct class *object_get_class(struct object *object)
    //@ requires globals(?objects, ?roots) &*& mem(object, objects) == true;
    //@ ensures globals(objects, roots);
{
    //@ open globals(_, _);
    //@ open heap(_, _);
    //@ foreach_remove(object, objects);
    //@ open object(objects)(object);
    return object->class;
    //@ close object(objects)(object);
    //@ foreach_unremove(object, objects);
    //@ close heap(objects, roots);
    //@ close globals(objects, roots);
}

void eval(struct object *data) //@ : apply_func
    //@ requires globals(?objects, ?roots) &*& mem(data, objects) == true;
    //@ ensures globals(_, roots);
{
    struct class *class;
    struct object *envs;
    struct object *forms;
    struct object *env;
    struct object *expr;
    destruct_cons(data, &envs, &expr);
    destruct_cons(envs, &forms, &env);
    
    class = object_get_class(expr);
    if (class == &atom_class) {
        struct object *value = assoc((void *)expr, env);
        if (value == 0) error("eval: no such binding");
        push(value);
    } else if (class == &cons_class) {
        struct object *f_expr;
        struct object *arg_expr;
        struct object *form = &nil_value;
        bool isForm;
        
        destruct_cons(expr, &f_expr, &arg_expr);
        
        class = object_get_class(f_expr);
        isForm = class == &atom_class;
        if (isForm) {
            struct object *value = assoc((void *)f_expr, forms);
            form = value;
            isForm = form != 0;
        }
        if (isForm) {
            void *value;
            push_root_g(&form);
            value = create_cons((void *)envs, arg_expr);
            push(value);
            //@ root_mem_g(&form);
            pop_root_g();
            apply((void *)form);
        } else {
            void *functionData;
            void *function;
            
            push_root_g(&envs);
            push_root_g(&f_expr);
            push_root_g(&arg_expr);
            
            functionData = create_nil();
            function = create_function(pop_apply, functionData);
            push_cont(function);
            
            //@ root_mem_g(&envs);
            //@ root_mem_g(&f_expr);
            functionData = create_cons(envs, f_expr);
            function = create_function(eval, functionData);
            push_cont(function);
            
            //@ root_mem_g(&envs);
            //@ root_mem_g(&arg_expr);
            functionData = create_cons(envs, arg_expr);
            function = create_function(eval, functionData);
            push_cont(function);
            
            pop_root_g();
            pop_root_g();
            pop_root_g();
        }
    } else
        error("Cannot evaluate: not an atom or a cons.");
}

void print_atom(struct object *data) //@ : apply_func
    //@ requires globals(?objects, ?roots) &*& mem(data, objects) == true;
    //@ ensures globals(_, roots);
{
    struct object *arg = pop();
    //@ open globals(_, _);
    //@ open heap(_, _);
    //@ foreach_remove(arg, objects);
    //@ open object(objects)(arg);
    if (arg->class != &atom_class) error("print_atom: argument is not an atom");
    //@ open class_info();
    //@ pointer_fractions_same_address(&arg->class->dispose, &atom_class.dispose);
    //@ merge_fractions atom_class.inv |-> _;
    //@ open atom_inv((void *)arg, _);
    print_string_buffer(((struct atom *)(void *)arg)->chars);
    //@ close atom_inv((void *)arg, nil);
    //@ close object(objects)(arg);
    //@ foreach_unremove(arg, objects);
    //@ close heap(objects, roots);
    //@ close globals(objects, roots);
    data = create_nil();
    push(data);
}

void quote_function(struct object *data) //@ : apply_func
    //@ requires globals(?objects, ?roots) &*& mem(data, objects) == true;
    //@ ensures globals(_, roots);
{
    struct object *arg = pop();
    struct object *envs;
    struct object *body;
    destruct_cons(arg, &envs, &body);
    push(body);
}

void fun_apply_function(struct object *data) //@ : apply_func
    //@ requires globals(?objects, ?roots) &*& mem(data, objects) == true;
    //@ ensures globals(_, roots);
{
    struct object *arg = pop();
    
    struct object *envs;
    struct object *forms;
    struct object *env;
    struct object *expr;
    struct object *param;
    struct object *body;
    
    struct class *paramClass;
    
    destruct_cons(data, &envs, &expr);
    destruct_cons(envs, &forms, &env);
    destruct_cons(expr, &param, &body);
    
    paramClass = object_get_class(param);
    if (paramClass != &atom_class)
        error("fun: param should be an atom");
    else {
        struct object *newEnv = env;
        void *newEnvs;
        void *newData;
        void *newFunction;
        
        push_root_g(&newEnv);
        push_root_g(&forms);
        push_root_g(&body);
        map_cons((void *)param, arg, &newEnv);
        
        //@ root_mem_g(&forms);
        //@ root_mem_g(&newEnv);
        newEnvs = create_cons(forms, newEnv);
        //@ root_mem_g(&body);
        newData = create_cons(newEnvs, body);
        newFunction = create_function(eval, newData);
        push_cont(newFunction);
        
        pop_root_g();
        pop_root_g();
        pop_root_g();
    }
}

void fun_function(struct object *data) //@ : apply_func
    //@ requires globals(?objects, ?roots);
    //@ ensures globals(_, roots);
{
    struct object *arg = pop();
    void *newFunction = create_function(fun_apply_function, arg);
    push(newFunction);
}

int my_getchar() //@ : charreader
    //@ requires true;
    //@ ensures true;
{
    return getchar();
}

/*@

lemma void init_heap()
    requires pointer(&heap_head, 0) &*& pointer(&roots_head, 0) &*& integer(&object_count, 0);
    ensures heap(nil, nil);
{
    close object_list(0, nil);
    close stack(0, nil);
    close foreach(nil, object(nil));
    close foreach(nil, root0(nil));
    close heap(nil, nil);
}

@*/

void init_globals()
    //@ requires module(gcl, true);
    //@ ensures globals(_, _);
{
    //@ open_module();
    //@ init_heap();
    
    //@ (&nil_class)->inv = nil_inv;
    //@ (&nil_class)->marking_inv = nil_marking_inv;
    //@ produce_function_pointer_chunk start_marking_func(nil_start_marking)(nil_inv, nil_marking_inv)(o, p) { call(); }
    //@ produce_function_pointer_chunk mark_next_func(nil_mark_next)(nil_inv, nil_marking_inv)(o, p) { call(); }
    //@ produce_function_pointer_chunk dispose_func(nil_dispose)(nil_inv)(o) { call(); }
    //@ leak class_name(&nil_class, _) &*& class_inv(&nil_class, _) &*& class_marking_inv(&nil_class, _);
    //@ leak class_start_marking(&nil_class, _) &*& class_mark_next(&nil_class, _) &*& class_dispose(&nil_class, _);
    
    //@ assume(&nil_value != 0);
    //@ close nil_inv(&nil_value, nil);
    //@ close roots(nil, nil, nil);
    register_object(&nil_value, &nil_class);
    push_root(&nil_root);
    //@ leak [_]pointer(&nil_root, _);
    
    push_root(&operand_stack);
    push_root(&cont_stack);
    
    //@ (&cons_class)->inv = cons_inv;
    //@ (&cons_class)->marking_inv = cons_marking_inv;
    //@ produce_function_pointer_chunk start_marking_func(cons_start_marking)(cons_inv, cons_marking_inv)(o, p) { call(); }
    //@ produce_function_pointer_chunk mark_next_func(cons_mark_next)(cons_inv, cons_marking_inv)(o, p) { call(); }
    //@ produce_function_pointer_chunk dispose_func(cons_dispose)(cons_inv)(o) { call(); }
    //@ leak class_name(&cons_class, _) &*& class_inv(&cons_class, _) &*& class_marking_inv(&cons_class, _);
    //@ leak class_start_marking(&cons_class, _) &*& class_mark_next(&cons_class, _) &*& class_dispose(&cons_class, _);
    
    //@ (&atom_class)->inv = atom_inv;
    //@ (&atom_class)->marking_inv = atom_marking_inv;
    //@ produce_function_pointer_chunk start_marking_func(atom_start_marking)(atom_inv, atom_marking_inv)(o, p) { call(); }
    //@ produce_function_pointer_chunk mark_next_func(atom_mark_next)(atom_inv, atom_marking_inv)(o, p) { call(); }
    //@ produce_function_pointer_chunk dispose_func(atom_dispose)(atom_inv)(o) { call(); }
    //@ leak class_name(&atom_class, _) &*& class_inv(&atom_class, _) &*& class_marking_inv(&atom_class, _);
    //@ leak class_start_marking(&atom_class, _) &*& class_mark_next(&atom_class, _) &*& class_dispose(&atom_class, _);
    
    //@ (&function_class)->inv = function_inv;
    //@ (&function_class)->marking_inv = function_marking_inv;
    //@ produce_function_pointer_chunk start_marking_func(function_start_marking)(function_inv, function_marking_inv)(o, p) { call(); }
    //@ produce_function_pointer_chunk mark_next_func(function_mark_next)(function_inv, function_marking_inv)(o, p) { call(); }
    //@ produce_function_pointer_chunk dispose_func(function_dispose)(function_inv)(o) { call(); }
    //@ leak class_name(&function_class, _) &*& class_inv(&function_class, _) &*& class_marking_inv(&function_class, _);
    //@ leak class_start_marking(&function_class, _) &*& class_mark_next(&function_class, _) &*& class_dispose(&function_class, _);
    
    //@ close class_info();
    //@ leak class_info();
    
    //@ assert heap(?objects, ?roots);
    //@ close globals(objects, roots);
}

int main() //@ : main_full(gcl)
    //@ requires module(gcl, true);
    //@ ensures true;
{
    void *object;
    struct object *forms;
    struct object *env;
    struct object *envs;
    struct tokenizer *tokenizer;
    
    init_globals();
    
    object = create_nil();
    forms = object;
    push_root_g(&forms);
    map_cons_s_func_nil("quote", quote_function, &forms);
    map_cons_s_func_nil("fun", fun_function, &forms);
    
    object = create_nil();
    env = object;
    push_root_g(&env);
    map_cons_s_func_nil("print_atom", print_atom, &env);
    
    //@ root_mem_g(&forms);
    //@ root_mem_g(&env);
    object = create_cons(forms, env);
    envs = object;
    push_root_g(&envs);
    
    tokenizer = tokenizer_create(my_getchar);
    
    //@ assert globals(_, ?roots);
    
    for (;;)
        //@ invariant globals(_, roots) &*& Tokenizer(tokenizer) &*& [1/2]pointer(&envs, _);
    {
        struct object *expr = parse(tokenizer);
        //@ root_mem_g(&envs);
        void *data = create_cons(envs, expr);
        void *cont = create_function(eval, data);
        push_cont(cont);
        
        for (;;)
            //@ invariant globals(_, roots);
        {
            object = pop_cont();
            if (object == 0) break;
            apply(object);
        }
        pop();
    }
}