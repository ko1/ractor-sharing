require 'mkmf'

# Declaring a table shareable without a traversal: newer rubies export
# rb_obj_set_shareable for it, older ones go through make_shareable, which for
# a FROZEN_SHAREABLE typed data amounts to the same thing.
have_func('rb_obj_set_shareable', 'ruby/ractor.h')

create_makefile('ractor/lock')
