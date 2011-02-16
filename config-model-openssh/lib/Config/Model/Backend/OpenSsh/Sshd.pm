package Config::Model::Backend::OpenSsh::Sshd ;

use Moose ;
extends "Config::Model::Backend::OpenSsh" ;

use Carp ;
use IO::File ;
use Log::Log4perl;
use File::Copy ;
use File::Path ;

my $logger = Log::Log4perl::get_logger("Backend::OpenSsh");

sub sshd_read {
    read_ssh_file( @_,  file => 'sshd_config',) ;
}

# for ssh_read:
# if root: use /etc/ssh/ssh_config as usual
# if normal user: load root file in "preset mode" 
#                 load ~/.ssh/config in normal mode
#                 write back to ~/.ssh/config
#                 Ssh model can only specify root config_dir

sub _ssh_read {
    my %args = @_ ;
    my $config_root = $args{object}
      || croak __PACKAGE__," ssh_read: undefined config root object";
    my $instance = $config_root -> instance ;

    my $is_user = 1 ;

    # $__test_root_file is a special global variable used only for tests
    $is_user = 0 if ($> == 0 or $__test_ssh_root_file ); 

    my $home_dir = $__test_ssh_home || $ENV{HOME} ;

    $logger->info("ssh_read: reading ".($is_user ? 'user' :'root').
		 " ssh config in ". ($is_user ? $home_dir : $args{config_dir}));

    $instance -> preset_start if $is_user ; # regular user

    my $ret = read_ssh_file( @_, file => 'ssh_config' ) ;

    $instance -> preset_stop if $is_user ;

    if ( $is_user) {
	# don't croak if user config file is missing
	 read_ssh_file( @_ , file => 'config',
		       config_dir => $home_dir.'/.ssh') ;
    }

    return $ret ;
}

my @dispatch = (
    qr/match/i                 => \&match,
    qr/host\b/i                => \&host,
    qr/(local|remote)forward/i => \&forward,
    qr/localcommand/i          => \&assign,
    qr/\w/                     => \&assign,
);

sub _read_ssh_file {
    my %args = @_ ;
    my $config_root = $args{object}
      || croak __PACKAGE__," read_ssh_file: undefined config root object";
    my $dir = $args{root}.$args{config_dir} ;

    unless (-d $dir ) {
	$logger->info("read_ssh_file: unknown config dir $dir");
	return 0;
    }

    my $file = $dir.'/'.$args{file} ;
    unless (-r "$file") {
	$logger->info("read_ssh_file: unknown file $file");
	return 0;
    }

    $logger->info("loading config file $file");

    my $fh = new IO::File $file, "r"  
        || die __PACKAGE__," read_ssh_file: can't open $file:$!";

    # try to get global comments (comments before a blank line)
    my @global_comments;
    my @comments;
    my $global_zone = 1;

    foreach ( $fh->getlines ) {
        next if /^##/;   # remove comments added by Config::Model
        chomp;

        my ( $vdata, $comment ) = split /\s*#\s?/;

        push @global_comments, $comment if defined $comment and $global_zone;
        push @comments, $comment if ( defined $comment and not $global_zone );

        if ( $global_zone and /^\s*$/ and @global_comments ) {
            $logger->debug("Setting global comment with '@global_comments'");
            $config_root->annotation(@global_comments);
            $global_zone = 0;
        }

        # stop global comment at first blank line
        $global_zone = 0 if /^\s*$/;

        if ( defined $vdata and $vdata ) {
            $vdata =~ s/^\s+//g;
            $vdata =~ s/\s+$//g;
            my ($k,@v) = split /\s+/,$vdata;
            
            my $i = 0;
            while ($i< @dispatch) {
                my ($regexp, $sub) = @dispatch[$i++,$i++];
                if ( $k =~ $regexp ) {
                    $self->$sub($config_root,\@v,\@comments) ;
                    last;
                }
            }

            warn __PACKAGE__," unknown keyword: $k" if $i >= @dispatch ;
        }
    $fh->close ;
    return 1;
}

sub _assign {
    my ($root, $key,$arg,$comment) = @_ ;
    $logger->debug("assign: $key @$arg # $comment");
    $current_node = $root unless defined $current_node ;

    # keys are case insensitive, try to find a match
    if ( not $current_node->element_exists( $key ) ) {
	foreach my $elt ($current_node->get_element_name(for => 'master') ) {
	    $key = $elt if lc($key) eq lc($elt) ;
	}
    }

    my $elt = $current_node->fetch_element($key) ;
    my $type = $elt->get_type;
    #print "got $key type $type and ",join('+',@$arg),"\n";
    if    ($type eq 'leaf') { 
	$elt->store( join(' ',@$arg) ) ;
    }
    elsif ($type eq 'list') { 
	$elt->push ( @$arg ) ;
    }
    elsif ($type eq 'hash') {
        $elt->fetch_with_id($arg->[0])->store( $arg->[1] );
    }
    elsif ($type eq 'check_list') {
	my @check = split /,/,$arg->[0] ;
        $elt->set_checked_list (@check) ;
    }
    else {
       die "OpenSsh::assign did not expect $type for $key\n";
    }
  }

sub _match {
    my ($root, $pairs,$comments) = @_ ;
    $logger->debug("match: @$pairs # @$comment");
    my $list_obj = $root->fetch_element('Match');

    # create new match block
    my $nb_of_elt = $list_obj->fetch_size;
    my $block_obj = $list_obj->fetch_with_id($nb_of_elt) ;
    $block_obj->annotation(@$comments) ;

    while (@$pairs) {
	my $criteria = shift @$pairs;
	my $pattern  = shift @$pairs;
	$block_obj->load(qq!Condition $criteria="$pattern"!);
    }

    $current_node = $block_obj->fetch_element('Settings');
}

sub _host {
    my ($root,$patterns,$comment)  = @_;
    $logger->debug("host: pattern @$patterns # $comment");
    my $hash_obj = $root->fetch_element('Host');

    $logger->info("ssh: load host patterns '".join("','", @$patterns)."'");

    $current_node = $hash_obj->fetch_with_id("@$patterns");
}

sub _forward {
    my ($root,$key,$args,$comment)  = @_;
    $logger->debug("forward: $key @$args # $comment");
    $current_node = $root unless defined $current_node ;

    my $elt_name = $key =~ /local/i ? 'Localforward' : 'RemoteForward' ;
    my $size = $current_node->fetch_element($key)->fetch_size;

    $logger->info("ssh: load $key '".join("','", @$args)."'");

    my $v6 = ($args->[1] =~ m![/\[\]]!) ? 1 : 0;

    # cleanup possible square brackets used for IPv6
    foreach (@$args) {s/[\[\]]+//g;}

    # reverse enable to assign string to port even if no bind_adress
    # is specified
    my $re = $v6 ? qr!/! : qr!:! ; 
    my ($port,$bind_adr ) = reverse split $re,$args->[0] ;
    my ($host,$host_port) = split $re,$args->[1] ;

    my $load_str = '';
    $load_str .= "GatewayPorts=1 " if $bind_adr ;

    $load_str .= "$key:$size ";

    $load_str .= 'ipv6=1 ' if $v6 ;

    $load_str .= "bind_address=$bind_adr " if defined $bind_adr ;
    $load_str .= "port=$port host=$host hostport=$host_port";

    $current_node -> load($load_str) ;
}

=head2 sshd_write (object => <sshd_root>, conf_dir => ...)

Write F<sshd_config> in C<conf_dir> from the data stored the
C<sshd_root> configuration tree.

=cut 

# now the write part

sub _sshd_write {
    my %args = @_ ;
    my $config_root = $args{object}
      || croak __PACKAGE__," sshd_write: undefined config root object";
    my $dir = $args{root}.$args{config_dir} ;

    mkpath($dir, {mode => 0755} )  unless -d $dir ;

    my $file = "$dir/sshd_config" ;
    if (-r "$file") {
	my $backup = "$file.".time.".bak" ;
	$logger->info("Backing up file $file in $backup");
	copy($file,$backup);
    }

    $logger->info("writing config file $file");

    my $result = write_node_content($config_root);

    #print $result ;
    open(OUT,"> $file") || die "cannot open $file:$!";
    print OUT $result;
    close OUT;

    return 1;
}

# for ssh_write:
# if root: use /etc/ssh/ssh_config as usual
# if normal user: load root file in "preset mode" 
#                 load ~/.ssh/config in normal mode
#                 write back to ~/.ssh/config
#                 Ssh model can only specify root config_dir

sub _ssh_write {
    my %args = @_ ;
    my $config_root = $args{object}
      || croak __PACKAGE__," ssh_write: undefined config root object";

    my $is_user = 1 ;
    # $__test_root_file is a special global variable used only for tests
    $is_user = 0 if ($> == 0 or $__test_ssh_root_file ); 
    my $home_dir = $__test_ssh_home || $ENV{HOME} ;

    my $config_dir = $is_user ? $home_dir.'/.ssh' : $args{config_dir} ;
    my $dir = $args{root}.$config_dir ;

    mkpath($dir, {mode => 0755} )  unless -d $dir ;

    my $file = $is_user ? "$dir/config" : "$dir/ssh_config" ;

    if (-r "$file") {
	my $backup = "$file.".time ;
	$logger->info("Backing up file $file in $backup");
	copy($file,$backup);
    }

    $logger->info("writing config file $file");

    my $result = write_node_content($config_root,'custom');

    #print $result ;
    open(OUT,"> $file") || die "cannot open $file:$!";
    print OUT $result;
    close OUT;

    return 1;
}

sub _write_line {
    return sprintf("%-20s %s\n",@_) ;
}

sub _write_node_content {
    my $node = shift ;
    my $mode = shift || '';

    my $result = '' ;
    my $match  = '' ;

    foreach my $name ($node->get_element_name(for => 'master') ) {
	next unless $node->is_element_defined($name) ;
	my $elt = $node->fetch_element($name) ;
	my $type = $elt->get_type;

	#print "got $key type $type and ",join('+',@arg),"\n";
	if    ($name eq 'Match') { 
	    $match .= write_all_match_block($elt,$mode) ;
	}
	elsif    ($name eq 'Host') { 
	    $match .= write_all_host_block($elt,$mode) ;
	}
	elsif    ($name =~ /^(Local|Remote)Forward$/) { 
	    map { $result .= write_forward($_,$mode) ;} $elt->fetch_all() ;
	}
#	elsif    ($name eq 'ClientAliveCheck') { 
#	    # special case that must be skipped
#	}
	elsif    ($type eq 'leaf') { 
	    my $v = $elt->fetch($mode) ;
	    if (defined $v and $elt->value_type eq 'boolean') {
		$v = $v == 1 ? 'yes':'no' ;
	    }
	    $result .= write_line($name,$v) if defined $v;
	}
	elsif    ($type eq 'check_list') { 
	    my $v = $elt->fetch($mode) ;
	    $result .= write_line($name,$v) if defined $v and $v;
	}
	elsif ($type eq 'list') { 
	    map { $result .= write_line($name,$_) ;} $elt->fetch_all_values($mode) ;
	}
	elsif ($type eq 'hash') {
	    foreach my $k ( $elt->get_all_indexes ) {
		my $v = $elt->fetch_with_id($k)->fetch($mode) ;
		$result .=  write_line($name,"$k $v") ;
	    }
	}
	else {
	    die "OpenSsh::write did not expect $type for $name\n";
	}
    }

    return $result.$match ;
}

sub write_all_match_block {
    my $match_elt = shift ;
    my $mode = shift || '';

    my $result = '' ;
    foreach my $elt ($match_elt->fetch_all($mode) ) {
	$result .= write_match_block($elt,$mode) ;
    }

    return $result ;
}

sub write_match_block {
    my $match_elt = shift ;
    my $mode = shift || '';

    my $result = "\nMatch " ;

    foreach my $name ($match_elt->get_element_name(for => 'master') ) {
	my $elt = $match_elt->fetch_element($name) ;

	if ($name eq 'Settings') {
	    $result .= "\n".write_node_content($elt,$mode)."\n" ;
	}
	elsif ($name eq 'Condition') {
	    $result .= write_match_condition($elt,$mode) ."\n" ;
	}
	else {
	    die "write_match_block: unexpected element: $name";
	}
    }

    return $result ;
}

sub write_match_condition {
    my $cond_elt = shift ;
    my $mode = shift || '';

    my $result = '' ;

    foreach my $name ($cond_elt->get_element_name(for => 'master') ) {
	my $elt = $cond_elt->fetch_element($name) ;
	my $v = $elt->fetch($mode) ;
	$result .= " $name $v" if defined $v;
    }

    return $result ;
}

sub write_all_host_block {
    my $host_elt = shift ;
    my $mode = shift || '';

    my $result = '' ;

    foreach my $pattern ( $host_elt->get_all_indexes) {
	my $block_elt = $host_elt->fetch_with_id($pattern) ;
	my $block_data = write_node_content($block_elt,'custom') ;

	# write data only if custom pattern or custom data is found this
	# is necessary to avoid writing data from /etc/ssh/ssh_config that
	# were entered as 'preset' data
	if ($block_data) {
	    $result .= "Host $pattern\n$block_data\n" ;
	}
    }
    return $result ;
}

sub write_forward {
    my $forward_elt = shift ;
    my $mode = shift || '';

    my $result = '' ;

    my $v6 = $forward_elt->grab_value('ipv6') ;
    my $sep = $v6 ? '/' : ':';

    my $line = '';
    foreach my $name ($forward_elt->get_element_name(for => 'master') ) {
	next if $name eq 'ipv6' ;
	my $elt = $forward_elt->fetch_element($name) ;
	my $v = $elt->fetch($mode) ;
	next unless defined $v;
	$line .=  $name =~ /bind|host$/ ? "$v$sep"
	       :  $name eq 'port'       ? "$v "
	       :                           $v ;
    }

    return write_line($forward_elt->element_name,$line) ;
}
1;

=head1 NAME

Config::Model::OpenSsh - OpenSsh config editor

=head1 SYNOPSIS

=head2 invoke editor

The following will launch a graphical editor (if L<Config::Model::TkUI>
is installed):

 config-edit -application sshd 

=head2 command line

This command will add a C<Host Foo> section in C<~/.ssh/config>: 

 config-edit -application ssh -ui none Host:Foo ForwardX11=yes
 
=head2 programmatic

This code snippet will remove the C<Host Foo> section added above:

 use Config::Model ;
 use Log::Log4perl qw(:easy) ;
 my $model = Config::Model -> new ( ) ;
 my $inst = $model->instance (root_class_name => 'Ssh');
 $inst -> config_root ->load("Host~Foo") ;
 $inst->write_back() ;

=head1 DESCRIPTION

This module provides a configuration editors (and models) for the 
configuration files of OpenSsh. (C</etc/ssh/sshd_config>, F</etc/ssh/ssh_config>
and C<~/.ssh/config>).

This module can also be used to modify safely the
content of these configuration files from a Perl programs.

Once this module is installed, you can edit C</etc/ssh/sshd_config> 
with run (as root) :

 # config-edit -application sshd 

To edit F</etc/ssh/ssh_config>, run (as root):

 # config-edit -application ssh

To edit F<~/.ssh/config>, run as a normal user:

 # config-edit -application ssh

=head1 user interfaces

As mentioned in L<config-edit>, several user interfaces are available:

=over

=item *

A graphical interface is proposed by default if L<Config::Model::TkUI> is installed.

=item *

A Curses interface with option C<-ui curses> if L<Config::Model::CursesUI> is installed.

=item *

A Shell like interface with option C<-ui term>.

=item *

A L<Fuse> virtual file system with option C<< -ui fuse -fuse_dir <mountpoint> >> 
if L<Fuse> is installed (Linux only)

=back

=head1 STOP

The documentation provides on the reader and writer of OpenSsh configuration files.
These details are not needed for the basic usages explained above.

=head1 Functions

These read/write functions are part of OpenSsh read/write backend. They are 
declared in OpenSsh configuration models and are called back when needed to read the 
configuration file and write it back.

=head2 sshd_read (object => <sshd_root>, conf_dir => ...)

Read F<sshd_config> in C<conf_dir> and load the data in the 
C<sshd_root> configuration tree.

=head1 AUTHOR

Dominique Dumont, (ddumont at cpan dot org)

=head1 LICENSE

   Copyright (c) 2008-2010 Dominique Dumont.

   This file is part of Config-Model-OpenSsh.

   Config-Model-OpenSsh is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser Public License as
   published by the Free Software Foundation; either version 2.1 of
   the License, or (at your option) any later version.

   Config-Xorg is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser Public License for more details.

   You should have received a copy of the GNU Lesser Public License
   along with Config-Model; if not, write to the Free Software
   Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA

=head1 SEE ALSO

L<config-edit-sshd>, L<config-edit-ssh>, L<Config::Model>,
