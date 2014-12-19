=head1 LICENSE

Copyright [1999-2014] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package EnsEMBL::Web::Component::Info;

use strict;

use base qw(EnsEMBL::Web::Component);

our $data_type = {
                  'Gene'      => {'param' => 'g', 'label' => 'Choose a Gene'},
                  'Variation' => {'param' => 'v', 'label' => 'Choose a Variant'},
                  'Location'  => {'param' => 'r', 'label' => 'Choose Coordinates'},
                  };

sub format_gallery {
  my ($self, $type, $layout, $all_pages) = @_;
  my ($html, @toc);

  foreach my $group (@$layout) {
    my @pages = @{$group->{'pages'}||[]};
    #next unless scalar @pages;

    my $title = $group->{'title'};
    push @toc, sprintf('<a href="#%s">%s</a>', lc($title), $title);
    $html .= sprintf('<h2 id="%s">%s</h2>', lc($title), $title);

    $html .= '<div class="gallery">';

    foreach (@pages) {
      my $page = $all_pages->{$_};
      next unless $page;

      $html .= '<div class="gallery_preview">';

      $html .= sprintf('<div class="preview_caption"><a href="%s" class="nodeco">%s</a></div><br />', $page->{'url'}, $page->{'caption'});

      $html .= sprintf('<a href="%s"><img src="/i/gallery/%s.png" /></a>', $page->{'url'}, $page->{'img'});

      my $form = $self->new_form({'action' => $page->{'url'}, 'method' => 'post'});

      my $data_param = $data_type->{$type}{'param'};
      my $field = $form->add_field({
                      'type'  => 'String',
                      'size'  => 10,
                      'name'  => $data_param,
                      'label' => $data_type->{$type}{'label'},
                      'value' => $self->hub->param($data_param),
                      });
      $field->add_element({'type' => 'submit', 'value' => 'Go'}, 1);

      $html .= '<div style="width:300px">'.$form->render.'</div>';

      $html .= '</div>';
    }


    $html .= '</div>';
  }
  my $toc_string = sprintf('<p class="center">%s</p>', join(' | ', @toc));

  return $toc_string.$html;  
}

1;
