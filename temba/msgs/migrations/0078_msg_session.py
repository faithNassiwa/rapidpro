# -*- coding: utf-8 -*-
# Generated by Django 1.10.5 on 2017-01-19 13:57
from __future__ import absolute_import, division, print_function, unicode_literals

from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('channels', '0055_install_indexes'),
        ('msgs', '0077_install_indexes'),
    ]

    operations = [
        migrations.AddField(
            model_name='msg',
            name='session',
            field=models.ForeignKey(help_text='The session this message was a part of if any', null=True, on_delete=django.db.models.deletion.CASCADE, to='channels.ChannelSession'),
        ),
    ]
