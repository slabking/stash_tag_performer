# stash_tag_performer

This is a script to tag your Stash performers with their ratings. Full disclosure: I 100% vibe coded this. Use at your own risk.

This runs just fine on my Mac running 26 Tahoe and Stash v0.30.1.

The core reason for this script is because I wanted to browse scenes by performer rating, and Stash doesn't currently support that. You can, however, filter scenes by performer tags, so I had GitHub Copilot write this for me. It took many, many iterations but it works great. I hope it helps someone else. This script works for both scenes and images.

In your Stash instance, you might need to create these tags prior to running the script:

```
rating_none
rating_1_star
rating_2_stars
rating_3_stars
rating_4_stars
rating_5_stars
```

The script is supposed to create them if they're missing, but I haven't tested that part. It might not work. I'd suggest setting them to ignore auto-tag.

Of course, edit line 5 to point to the URL of your Stash instance. You should be able to add an API key to line 9, but I haven't tested that at all.

After running this script, just perform a scene search for Performer Tags include rating_5_stars (or whatever you'd like). If you change a rating for a performer and run the script again, it'll remove the old tag and add the correct one.

Note: I am using these settings in Stash > Settings > Interface:

Rating System Type: Stars
Rating Star Precision: Full

I'd guess the script won't work if you change either of these.
