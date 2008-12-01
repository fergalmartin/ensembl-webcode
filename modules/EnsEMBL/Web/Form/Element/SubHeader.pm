package EnsEMBL::Web::Form::Element::SubHeader;

use EnsEMBL::Web::Form::Element;
our @ISA = qw( EnsEMBL::Web::Form::Element );

sub new {
  my $class = shift;
  return $class->SUPER::new( @_, 'layout' => 'spanning' );
}

sub render { return '<tr><td colspan="2" style="text-align:left"><strong>'.$_[0]->value.'</strong></td></tr>'; }

1;
