requires 'perl', '5.014000';
requires 'GraphQL', '0.54';

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'Test::Deep', '1.205';
    requires 'Test::Exception', '0.43';
};
