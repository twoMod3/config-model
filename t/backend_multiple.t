# -*- cperl -*-

use Test::More;
use Test::Memory::Cycle;
use Config::Model;
use File::Path;
use File::Copy;
use Test::Warn;
use Test::Exception;

use Config::Model::Tester::Setup qw/init_test setup_test_dir/;

use warnings;
use strict;
use lib 't/lib';

my ($model, $trace) = init_test();

# pseudo root where config files are written by config-model
my $wr_root = setup_test_dir( stringify => 1 );

$model->create_config_class(
    'rw_config' => {
        'auto_create' => '1',
        'file'        => 'control.pl',
        'backend'     => 'perl_file',
        'config_dir'  => 'debian'
    },
    'name'    => 'Test::Control',
    'element' => [ 'source' => { 'type' => 'leaf', value_type => 'string', } ]
);

$model->create_config_class(
    'rw_config' => {
        'auto_create' => '1',
        'file'        => 'copyright.pl',
        'backend'     => 'perl_file',
        'config_dir'  => 'debian'
    },
    'name'    => 'Test::Copyright',
    'element' => [ 'Format', { 'value_type' => 'uniline', 'type' => 'leaf', }, ]
);

$model->create_config_class(
    'rw_config' => {
        'auto_create' => '1',
        'backend'     => 'PlainFile',
        'config_dir'  => 'debian/source'
    },
    'name'    => 'Test::Source',
    'element' => [ 'format', { 'value_type' => 'uniline', 'type' => 'leaf', } ]
);

$model->create_config_class(
    'rw_config' => {
        auto_create => 1,
        auto_delete => 1,
        # test minimal spec with custom backend class
        backend     => 'Mini'
    },
    'name'    => 'Test::Meta',
    'element' => [ 'email', { 'value_type' => 'uniline', 'type' => 'leaf', } ]
);

$model->create_config_class(
    'name'    => 'Test::Dpkg',
    'element' => [
        control => {
            type              => 'node',
            config_class_name => 'Test::Control'
        },
        copyright => {
            type              => 'node',
            config_class_name => 'Test::Copyright'
        },
        source => {
            type              => 'node',
            config_class_name => 'Test::Source'
        },
        meta => {
            type => 'node',
            config_class_name => 'Test::Meta'
        },
    ]
);

my $inst = $model->instance( root_class_name => 'Test::Dpkg', root_dir => $wr_root, );
my $root = $inst->config_root;

$root->load(
    'control source=ctrl-source -
     copyright Format=copyright-format -
     source format=source-format -
     meta email=joe@foo.com'
);
ok( 1, "loaded data" );

my $dump = $root->dump_tree;
print $dump if $trace;

$inst->write_back;

#check written files
foreach (qw!control.pl copyright.pl source/format meta/test.yml!) {
    my $f = $wr_root . "debian/$_";
    ok( -e $f, "check written file $f" );
}

my $inst2 = $model->instance(
    root_class_name => 'Test::Dpkg',
    root_dir        => $wr_root,
    instance_name   => 'test2'
);
my $root2 = $inst2->config_root;
my $dump2 = $root2->dump_tree;
is( $dump2, $dump, "check that inst2 is a copy of first instance" );

memory_cycle_ok($model, "check memory cycles");
done_testing;
