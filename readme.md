### Restic rest server
* https://github.com/restic/rest-server
* Create http server user with `docker exec -it restic-rest-server create_user username`
* init a repo and save password to restic-password.txt
    * `restic -r rest:http://username:password@backup.duobit.ro:8000/repo init`
* more on https://restic.net/#quickstart

